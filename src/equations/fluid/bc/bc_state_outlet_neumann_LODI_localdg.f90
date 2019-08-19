module bc_state_outlet_neumann_LODI_localdg
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO, ONE, HALF, TWO, FOUR, NFACES, ME, NO_ID
    use mod_fluid,              only: gam, Rgas

    use type_mesh,              only: mesh_t
    use type_element_info,      only: element_info_t, element_info
    use type_bc_state,          only: bc_state_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use type_point,             only: point_t
    use mpi_f08,                only: mpi_comm
    use mod_interpolate,        only: interpolate_face_autodiff, interpolate_element_autodiff
    use mod_fgmres_standard,    only: fgmres_autodiff
    use mod_inv,                only: inv
    use ieee_arithmetic
    use DNAD_D
    implicit none


    !> Extrapolation boundary condition 
    !!      - Extrapolate interior variables to be used for calculating the boundary flux.
    !!  
    !!  @author Nathan A. Wukie
    !!  @date   1/31/2016
    !!
    !----------------------------------------------------------------------------------------
    type, public, extends(bc_state_t) :: outlet_neumann_LODI_localdg_t

    contains

        procedure   :: init                 ! Set-up bc state with options/name etc.
        procedure   :: compute_bc_state     ! boundary condition function implementation
        procedure   :: init_bc_coupling     ! Implement specialized initialization procedure
        procedure   :: compute_averages


        procedure   :: compute_local_linearization
        procedure   :: compute_local_residual_pressure
        procedure   :: compute_local_residual_vn
        procedure   :: compute_local_residual_density
        procedure   :: converge_local_problem_pressure
        procedure   :: converge_local_problem_vn
        procedure   :: converge_local_problem_density

    end type outlet_neumann_LODI_localdg_t
    !****************************************************************************************




contains



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/29/2016
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(outlet_neumann_LODI_localdg_t),   intent(inout) :: self
        
        !
        ! Set name, family
        !
        call self%set_name("Outlet - Neumann LODI Local DG")
        call self%set_family("Outlet")

        call self%bcproperties%add('Average Pressure', 'Required')

    end subroutine init
    !********************************************************************************




    !>  Initialize boundary group coupling.
    !!
    !!  Call global coupling routine to initialize implicit coupling between each
    !!  element with every other element on the boundary, a result of averaging
    !!  and Fourier transform operations.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/18/2018
    !!
    !--------------------------------------------------------------------------------
    subroutine init_bc_coupling(self,mesh,group_ID,bc_comm)
        class(outlet_neumann_LODI_localdg_t),   intent(inout)   :: self
        type(mesh_t),                               intent(inout)   :: mesh
        integer(ik),                                intent(in)      :: group_ID
        type(mpi_comm),                             intent(in)      :: bc_comm

        call self%init_bc_coupling_global(mesh,group_ID,bc_comm)

    end subroutine init_bc_coupling
    !********************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/13/2018
    !!
    !--------------------------------------------------------------------------------
    subroutine compute_local_linearization(self,worker,bc_comm,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        class(outlet_neumann_LODI_localdg_t),    intent(inout)   :: self
        type(chidg_worker_t),                       intent(inout)   :: worker
        type(mpi_comm),                             intent(in)      :: bc_comm
        type(AD_D),                                 intent(in)      :: p_avg
        type(AD_D),                                 intent(in)      :: c_avg
        type(AD_D),                                 intent(in)      :: density_avg
        type(AD_D),                                 intent(in)      :: M1_avg
        type(AD_D),                                 intent(in)      :: M2_avg
        type(AD_D),                                 intent(in)      :: M3_avg


        type(AD_D), allocatable, dimension(:)   ::  &
            zero_face, R_modes_i, R_modes_p, p_modes_perturb, tmp, p_modes

        real(rk),   allocatable, dimension(:,:) :: dRdp, inv_dRdp
        real(rk)    :: pert
        integer(ik) :: idomain_l, ielement_l, iface, nterms_s, group_ID, &
                       patch_ID, face_ID, ierr, i


        ! Get location on domain
        idomain_l  = worker%element_info%idomain_l
        ielement_l = worker%element_info%ielement_l
        iface      = worker%iface
        nterms_s   = worker%mesh%domain(idomain_l)%elems(ielement_l)%nterms_s


        if (.not. worker%mesh%domain(idomain_l)%elems(ielement_l)%bc_initialized) then

            ! Get location on bc_patch_group
            group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
            patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
            face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID


            ! Initialize empty array with derivatives allocated
            zero_face = worker%get_field('Density','value','face interior')
            zero_face = ZERO


            ! Initialize p_modes storage with derivatives
            nterms_s = worker%mesh%domain(idomain_l)%elems(ielement_l)%nterms_s
            allocate(p_modes(nterms_s), stat=ierr)
            if (ierr /= 0) call AllocationError
            p_modes(:) = zero_face(1)
            if (size(p_modes) /= nterms_s) call chidg_signal(FATAL,'outlet_neumann_LODI_localdg: converge_p Error 1.')


            ! Allocate jacobian matrix
            allocate(dRdp(nterms_s,nterms_s), stat=ierr)
            if (ierr /= 0) call AllocationError


            ! Construct linearization via finite-difference
            ! approximation of the jacobian matrix.
            R_modes_i = self%compute_local_residual_pressure(worker,bc_comm,p_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
            pert = 1.e-8_rk
            do i = 1,size(p_modes)
                p_modes_perturb = p_modes
                p_modes_perturb(i) = p_modes_perturb(i) + pert
                R_modes_p = self%compute_local_residual_pressure(worker,bc_comm,p_modes_perturb,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)

                tmp = (R_modes_p - R_modes_i)/pert
                dRdp(:,i) = tmp(:)%x_ad_
            end do

            ! Invert jacobian
            inv_dRdp = inv(dRdp)
                    
            ! Store and register initialized
            worker%mesh%domain(idomain_l)%elems(ielement_l)%bc = inv_dRdp
            worker%mesh%domain(idomain_l)%elems(ielement_l)%bc_initialized = .true.

        end if ! .not. initialized


    end subroutine compute_local_linearization
    !**********************************************************************************************




    !>  Update the area-averaged pressure for the boundary condition.
    !!
    !!  @author Nathan A. average_pressure
    !!  @date   3/31/2017
    !!
    !-------------------------------------------------------------------------------------------
    subroutine compute_averages(self,worker,bc_COMM, p_avg, c_avg, density_avg, M1_avg,M2_avg,M3_avg)
        class(outlet_neumann_LODI_localdg_t),  intent(inout)   :: self
        type(chidg_worker_t),                           intent(inout)   :: worker
        type(mpi_comm),                                 intent(in)      :: bc_COMM
        type(AD_D),                                     intent(inout)   :: p_avg
        type(AD_D),                                     intent(inout)   :: c_avg
        type(AD_D),                                     intent(inout)   :: density_avg
        type(AD_D),                                     intent(inout)   :: M1_avg
        type(AD_D),                                     intent(inout)   :: M2_avg
        type(AD_D),                                     intent(inout)   :: M3_avg

        type(AD_D)          :: face_p, face_c, face_density, face_M1, face_M2, face_M3, &
                               p_integral, c_integral, density_integral, M1_integral, M2_integral, M3_integral
        type(element_info_t)    :: coupled_element

        type(AD_D), allocatable,    dimension(:)    :: pressure, density, mom1, mom2, mom3, energy, c, M1, M2, M3
        real(rk),   allocatable,    dimension(:)    :: weights, areas, r

        integer(ik) :: ipatch, iface_bc, idomain_l, ielement_l, iface, ierr, itime, &
                       idensity, imom1, imom2, imom3, ienergy, group_ID, patch_ID, face_ID, &
                       icoupled, idomain_g_coupled, idomain_l_coupled, ielement_g_coupled,  &
                       ielement_l_coupled, iface_coupled, coupled_iface
        real(rk)    :: face_area, total_area



        !
        ! Zero integrated quantities
        !
        total_area = ZERO


        ! Get location on domain
        idomain_l  = worker%element_info%idomain_l
        ielement_l = worker%element_info%ielement_l
        iface      = worker%iface

        ! Get location on bc_patch_group
        group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
        patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
        face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID


        !
        ! Loop through coupled faces and compute their contribution to the average pressure
        !
        do icoupled = 1,worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%ncoupled_elements(face_ID)

            ! Get face info from coupled element we want to interpolate from
            idomain_g_coupled  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_g( icoupled)
            idomain_l_coupled  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_l( icoupled)
            ielement_g_coupled = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_g(icoupled)
            ielement_l_coupled = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_l(icoupled)
            iface_coupled      = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%iface(     icoupled)

            coupled_element = element_info(idomain_g       = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_g(icoupled),        &
                                           idomain_l       = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_l(icoupled),        &
                                           ielement_g      = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_g(icoupled),       &
                                           ielement_l      = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_l(icoupled),       &
                                           iproc           = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%proc(icoupled),             &
                                           pelem_ID        = NO_ID,                                                                                             &
                                           eqn_ID          = NO_ID,                                                                                             &
                                           nfields         = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%nfields(icoupled),          &
                                           ntime           = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ntime(icoupled),            &
                                           nterms_s        = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%nterms_s(icoupled),         &
                                           nterms_c        = 0,                                                                                                 &
                                           dof_start       = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%dof_start(icoupled),        &
                                           dof_local_start = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%dof_local_start(icoupled),  &
                                           recv_comm       = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%recv_comm(icoupled),        &
                                           recv_domain     = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%recv_domain(icoupled),      &
                                           recv_element    = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%recv_element(icoupled),     &
                                           recv_dof        = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%recv_dof(icoupled))

            coupled_iface = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%iface(icoupled)





            ! Get solution
            idensity = 1
            imom1    = 2
            imom2    = 3
            imom3    = 4
            ienergy  = 5
            itime    = 1

            ! Interpolate coupled element solution on face of coupled element
            density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,coupled_element,worker%function_info,coupled_iface, idensity, itime, 'value', ME)
            mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,coupled_element,worker%function_info,coupled_iface, imom1,    itime, 'value', ME)
            mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,coupled_element,worker%function_info,coupled_iface, imom2,    itime, 'value', ME)
            mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,coupled_element,worker%function_info,coupled_iface, imom3,    itime, 'value', ME)
            energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,coupled_element,worker%function_info,coupled_iface, ienergy,  itime, 'value', ME)

            if (worker%coordinate_system() == 'Cylindrical') then
                mom2 = mom2 / worker%mesh%domain(idomain_l_coupled)%elems(ielement_l_coupled)%interp_coords_def(:,1)
            end if
            
            ! Compute quantities for averaging
            pressure = (gam-ONE)*(energy - HALF*(mom1*mom1 + mom2*mom2 + mom3*mom3)/density)
            c = sqrt(gam*pressure/density)
            M1 = (mom1/density)/c
            M2 = (mom2/density)/c
            M3 = (mom3/density)/c

            ! Get weights + areas
            weights   = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%weights_face(iface_coupled)
            areas     = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%data(icoupled)%areas
            face_area = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%data(icoupled)%total_area

            ! Integrate and contribute to average
            face_p = sum(pressure*areas*weights)
            face_c = sum(c*areas*weights)
            face_density = sum(density*areas*weights)
            face_M1 = sum(M1*areas*weights)
            face_M2 = sum(M2*areas*weights)
            face_M3 = sum(M3*areas*weights)

            if (allocated(p_integral%xp_ad_)) then
                p_integral = p_integral + face_p
            else
                p_integral = face_p
            end if

            if (allocated(c_integral%xp_ad_)) then
                c_integral = c_integral + face_c
            else
                c_integral = face_c
            end if

            if (allocated(density_integral%xp_ad_)) then
                density_integral = density_integral + face_density
            else
                density_integral = face_density
            end if

            if (allocated(M1_integral%xp_ad_)) then
                M1_integral = M1_integral + face_M1
            else
                M1_integral = face_M1
            end if

            if (allocated(M2_integral%xp_ad_)) then
                M2_integral = M2_integral + face_M2
            else
                M2_integral = face_M2
            end if

            if (allocated(M3_integral%xp_ad_)) then
                M3_integral = M3_integral + face_M3
            else
                M3_integral = face_M3
            end if

            total_area = total_area + face_area

        end do !icoupled

        ! Compute average pressure:
        !   area-weighted pressure integral over the total area
        p_avg = p_integral / total_area
        c_avg = c_integral / total_area
        M1_avg = M1_integral / total_area
        M2_avg = M2_integral / total_area
        M3_avg = M3_integral / total_area
        density_avg = density_integral / total_area

    end subroutine compute_averages
    !*******************************************************************************************






    !>  Compute routine for Pressure Outlet boundary condition state function.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/3/2016
    !!
    !!  @param[in]      worker  Interface for geometry, cache, integration, etc.
    !!  @param[inout]   prop    properties_t object containing equations and material_t objects
    !!
    !-----------------------------------------------------------------------------------------
    subroutine compute_bc_state(self,worker,prop,bc_COMM)
        class(outlet_neumann_LODI_localdg_t),  intent(inout)   :: self
        type(chidg_worker_t),               intent(inout)   :: worker
        class(properties_t),                intent(inout)   :: prop
        type(mpi_comm),                     intent(in)      :: bc_COMM

        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:)   ::                      &
            density_m,  mom1_m,  mom2_m,  mom3_m,  energy_m,            &
            density_bc, mom1_bc, mom2_bc, mom3_bc, energy_bc,           &
            grad1_density_m, grad1_mom1_m, grad1_mom2_m, grad1_mom3_m, grad1_energy_m,  &
            grad2_density_m, grad2_mom1_m, grad2_mom2_m, grad2_mom3_m, grad2_energy_m,  &
            grad3_density_m, grad3_mom1_m, grad3_mom2_m, grad3_mom3_m, grad3_energy_m,  &
            v1_bc, v2_bc, v3_bc, T_m, T_bc, p_bc, p_modes, vn_modes, density_modes, vn_bc, v1_m, v2_m, v3_m, &
            vn_m, vn_m_1, vn_m_2, vn_m_3, vt_m_1, vt_m_2, vt_m_3, p_m

        type(AD_D)  :: p_avg, c_avg, density_avg, M1_avg, M2_avg, M3_avg

        real(rk),   allocatable, dimension(:)   :: r
            

        ! Compute average pressure: p_avg
        call self%compute_averages(worker,bc_comm,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)

        ! Make sure local problem linearization is initialized
        call self%compute_local_linearization(worker,bc_comm,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)

        ! Converge element-local problem: p_modes
        call self%converge_local_problem_pressure(worker,bc_comm,p_modes,      p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        call self%converge_local_problem_vn(      worker,bc_comm,vn_modes,     p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        !call self%converge_local_problem_density( worker,bc_comm,density_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)

        ! Compute boundary state with that from element-local problem just solved
        associate( val => worker%mesh%domain(worker%element_info%idomain_l)%faces(worker%element_info%ielement_l,worker%iface)%basis_s%interpolator_face('Value',worker%iface) )
            p_bc       = matmul(val,p_modes)
            vn_bc      = matmul(val,vn_modes)
            !density_bc = matmul(val,density_modes)
        end associate

        print*, 'pressure: ', p_bc(:)%x_ad_
        print*, 'vn_bc: ', vn_bc(:)%x_ad_
        !print*, 'density: ', density_bc(:)%x_ad_

        ! Interpolate interior solution to face quadrature nodes
        density_m = worker%get_field('Density'    , 'value', 'face interior')
        mom1_m    = worker%get_field('Momentum-1' , 'value', 'face interior')
        mom2_m    = worker%get_field('Momentum-2' , 'value', 'face interior')
        mom3_m    = worker%get_field('Momentum-3' , 'value', 'face interior')
        energy_m  = worker%get_field('Energy'     , 'value', 'face interior')
        T_m       = worker%get_field('Temperature', 'value', 'face interior')
        p_m       = worker%get_field('Pressure',    'value', 'face interior')



        grad1_density_m = worker%get_field('Density'   , 'grad1', 'face interior')
        grad2_density_m = worker%get_field('Density'   , 'grad2', 'face interior')
        grad3_density_m = worker%get_field('Density'   , 'grad3', 'face interior')

        grad1_mom1_m    = worker%get_field('Momentum-1', 'grad1', 'face interior')
        grad2_mom1_m    = worker%get_field('Momentum-1', 'grad2', 'face interior')
        grad3_mom1_m    = worker%get_field('Momentum-1', 'grad3', 'face interior')

        grad1_mom2_m    = worker%get_field('Momentum-2', 'grad1', 'face interior')
        grad2_mom2_m    = worker%get_field('Momentum-2', 'grad2', 'face interior')
        grad3_mom2_m    = worker%get_field('Momentum-2', 'grad3', 'face interior')

        grad1_mom3_m    = worker%get_field('Momentum-3', 'grad1', 'face interior')
        grad2_mom3_m    = worker%get_field('Momentum-3', 'grad2', 'face interior')
        grad3_mom3_m    = worker%get_field('Momentum-3', 'grad3', 'face interior')
        
        grad1_energy_m  = worker%get_field('Energy'    , 'grad1', 'face interior')
        grad2_energy_m  = worker%get_field('Energy'    , 'grad2', 'face interior')
        grad3_energy_m  = worker%get_field('Energy'    , 'grad3', 'face interior')


        ! Account for cylindrical. Get tangential momentum from angular momentum.
        r = worker%coordinate('1','boundary')
        if (worker%coordinate_system() == 'Cylindrical') then
            mom2_m = mom2_m / r
        end if

        ! Extrapolate temperature and velocity
        T_bc = T_m
        v1_m = mom1_m/density_m
        v2_m = mom2_m/density_m
        v3_m = mom3_m/density_m


        ! Compute normal velocity from interior
        vn_m = v1_m*worker%unit_normal(1) + v2_m*worker%unit_normal(2) + v3_m*worker%unit_normal(3)
        vn_m_1 = vn_m*worker%unit_normal(1)
        vn_m_2 = vn_m*worker%unit_normal(2)
        vn_m_3 = vn_m*worker%unit_normal(3)

        ! Subtract interior normal velocity to get transverse interior velocity
        vt_m_1 = v1_m - vn_m_1
        vt_m_2 = v2_m - vn_m_2
        vt_m_3 = v3_m - vn_m_3

        ! Add back normal velocity from LODI boundary condition
        v1_bc = vt_m_1 + vn_bc*worker%unit_normal(1)
        v2_bc = vt_m_2 + vn_bc*worker%unit_normal(2)
        v3_bc = vt_m_3 + vn_bc*worker%unit_normal(3)
        !v1_bc = vt_m_1 + vn_m*worker%unit_normal(1)
        !v2_bc = vt_m_2 + vn_m*worker%unit_normal(2)
        !v3_bc = vt_m_3 + vn_m*worker%unit_normal(3)


        ! Compute density, momentum, energy
        !v1_bc = v1_m
        !v2_bc = v2_m
        !v3_bc = v3_m
        p_bc = p_m
        density_bc = p_bc/(Rgas*T_bc)
        mom1_bc    = v1_bc*density_bc
        mom2_bc    = v2_bc*density_bc
        mom3_bc    = v3_bc*density_bc
        energy_bc  = p_bc/(gam - ONE) + (density_bc*HALF)*(v1_bc*v1_bc + v2_bc*v2_bc + v3_bc*v3_bc)

        ! Account for cylindrical. Convert tangential momentum back to angular momentum.
        if (worker%coordinate_system() == 'Cylindrical') then
            mom2_bc = mom2_bc * r
        end if

        ! Store boundary condition state
        call worker%store_bc_state('Density'   , density_bc, 'value')
        call worker%store_bc_state('Momentum-1', mom1_bc,    'value')
        call worker%store_bc_state('Momentum-2', mom2_bc,    'value')
        call worker%store_bc_state('Momentum-3', mom3_bc,    'value')
        call worker%store_bc_state('Energy'    , energy_bc,  'value')


        ! Store boundary condition gradient
        call worker%store_bc_state('Density'   , grad1_density_m, 'grad1')
        call worker%store_bc_state('Density'   , grad2_density_m, 'grad2')
        call worker%store_bc_state('Density'   , grad3_density_m, 'grad3')
                                                
        call worker%store_bc_state('Momentum-1', grad1_mom1_m,    'grad1')
        call worker%store_bc_state('Momentum-1', grad2_mom1_m,    'grad2')
        call worker%store_bc_state('Momentum-1', grad3_mom1_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-2', grad1_mom2_m,    'grad1')
        call worker%store_bc_state('Momentum-2', grad2_mom2_m,    'grad2')
        call worker%store_bc_state('Momentum-2', grad3_mom2_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-3', grad1_mom3_m,    'grad1')
        call worker%store_bc_state('Momentum-3', grad2_mom3_m,    'grad2')
        call worker%store_bc_state('Momentum-3', grad3_mom3_m,    'grad3')
                                                
        call worker%store_bc_state('Energy'    , grad1_energy_m,  'grad1')
        call worker%store_bc_state('Energy'    , grad2_energy_m,  'grad2')
        call worker%store_bc_state('Energy'    , grad3_energy_m,  'grad3')


    end subroutine compute_bc_state
    !**************************************************************************************




    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/6/2018
    !!
    !------------------------------------------------------------------------------
    subroutine compute_pressure_gradient(worker,grad1_p, grad2_p, grad3_p) 
        type(chidg_worker_t),                   intent(inout)   :: worker
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad1_p 
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad2_p 
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad3_p 

        type(AD_D), allocatable, dimension(:)   ::                              &
            density,       mom1,       mom2,       mom3,       energy,          &
            grad1_density, grad1_mom1, grad1_mom2, grad1_mom3, grad1_energy,    &
            grad2_density, grad2_mom1, grad2_mom2, grad2_mom3, grad2_energy,    &
            grad3_density, grad3_mom1, grad3_mom2, grad3_mom3, grad3_energy,    &
            dp_ddensity, dp_dmom1, dp_dmom2, dp_dmom3, dp_denergy

        real(rk),   allocatable, dimension(:)   :: r

        ! Interpolate solution to quadrature nodes
        density       = worker%get_field('Density',    'value')
        mom1          = worker%get_field('Momentum-1', 'value')
        mom2          = worker%get_field('Momentum-2', 'value')
        mom3          = worker%get_field('Momentum-3', 'value')
        energy        = worker%get_field('Energy',     'value')

        if (worker%interpolation_source == 'element') then

            grad1_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad1')
            grad1_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad1')
            grad1_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad1')
            grad1_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad1')
            grad1_energy  = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 5, worker%itime, 'grad1')

            grad2_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad2')
            grad2_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad2')
            grad2_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad2')
            grad2_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad2')
            grad2_energy  = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 5, worker%itime, 'grad2')

            grad3_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad3')
            grad3_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad3')
            grad3_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad3')
            grad3_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad3')
            grad3_energy  = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 5, worker%itime, 'grad3')

        else

            grad1_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 1, worker%itime, 'grad1', ME)
            grad1_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 2, worker%itime, 'grad1', ME)
            grad1_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 3, worker%itime, 'grad1', ME)
            grad1_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 4, worker%itime, 'grad1', ME)
            grad1_energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 5, worker%itime, 'grad1', ME)

            grad2_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 1, worker%itime, 'grad2', ME)
            grad2_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 2, worker%itime, 'grad2', ME)
            grad2_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 3, worker%itime, 'grad2', ME)
            grad2_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 4, worker%itime, 'grad2', ME)
            grad2_energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 5, worker%itime, 'grad2', ME)

            grad3_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 1, worker%itime, 'grad3', ME)
            grad3_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 2, worker%itime, 'grad3', ME)
            grad3_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 3, worker%itime, 'grad3', ME)
            grad3_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 4, worker%itime, 'grad3', ME)
            grad3_energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 5, worker%itime, 'grad3', ME)

        end if



        ! Account for cylindrical. Get tangential momentum from angular momentum.
        ! Also convert derivatives from derivatives of angular momentum to tangential.
        !
        ! We want:
        !       (rho * u_theta)  instead of      (r * rho * u_theta)
        !   grad(rho * u_theta)  instead of  grad(r * rho * u_theta)
        !
        !   grad(rho * u_theta) = grad(r * rho * u_theta)/r  -  grad(r)(rho*u_theta)/r
        !
        ! Where grad(r) = [1,0,0]
        !
        if (worker%coordinate_system() == 'Cylindrical') then
            r = worker%coordinate('1')
            mom2       = mom2 / r
            grad1_mom2 = (grad1_mom2/r) - mom2/r
            grad2_mom2 = (grad2_mom2/r)
            grad3_mom2 = (grad3_mom2/r)
        end if

        ! Compute pressure jacobians
        dp_ddensity =  (gam-ONE)*HALF*(mom1*mom1 + mom2*mom2 + mom3*mom3)/(density*density)
        dp_dmom1    = -(gam-ONE)*mom1/density
        dp_dmom2    = -(gam-ONE)*mom2/density
        dp_dmom3    = -(gam-ONE)*mom3/density
        dp_denergy  = dp_ddensity ! init storage
        dp_denergy  =  (gam-ONE)

        ! Compute pressure gradient
        grad1_p = dp_ddensity * grad1_density  + &
                  dp_dmom1    * grad1_mom1     + &
                  dp_dmom2    * grad1_mom2     + &
                  dp_dmom3    * grad1_mom3     + &
                  dp_denergy  * grad1_energy

        grad2_p = dp_ddensity * grad2_density  + &
                  dp_dmom1    * grad2_mom1     + &
                  dp_dmom2    * grad2_mom2     + &
                  dp_dmom3    * grad2_mom3     + &
                  dp_denergy  * grad2_energy

        grad3_p = dp_ddensity * grad3_density  + &
                  dp_dmom1    * grad3_mom1     + &
                  dp_dmom2    * grad3_mom2     + &
                  dp_dmom3    * grad3_mom3     + &
                  dp_denergy  * grad3_energy

    end subroutine compute_pressure_gradient
    !******************************************************************************


    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/6/2018
    !!
    !------------------------------------------------------------------------------
    subroutine compute_velocity_gradient(worker,grad1_v1, grad2_v1, grad3_v1, &
                                                grad1_v2, grad2_v2, grad3_v2, &
                                                grad1_v3, grad2_v3, grad3_v3) 
        type(chidg_worker_t),                   intent(inout)   :: worker
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad1_v1
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad2_v1
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad3_v1
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad1_v2
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad2_v2
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad3_v2
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad1_v3
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad2_v3
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad3_v3

        type(AD_D), allocatable, dimension(:)   ::              &
            density,       mom1,       mom2,       mom3,        &
            grad1_density, grad1_mom1, grad1_mom2, grad1_mom3,  &
            grad2_density, grad2_mom1, grad2_mom2, grad2_mom3,  &
            grad3_density, grad3_mom1, grad3_mom2, grad3_mom3,  &
            v1, v2, v3

        real(rk),   allocatable, dimension(:)   :: r

        ! Interpolate solution to quadrature nodes
        density       = worker%get_field('Density',    'value')
        mom1          = worker%get_field('Momentum-1', 'value')
        mom2          = worker%get_field('Momentum-2', 'value')
        mom3          = worker%get_field('Momentum-3', 'value')

        if (worker%interpolation_source == 'element') then

            grad1_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad1')
            grad1_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad1')
            grad1_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad1')
            grad1_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad1')

            grad2_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad2')
            grad2_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad2')
            grad2_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad2')
            grad2_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad2')

            grad3_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad3')
            grad3_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad3')
            grad3_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad3')
            grad3_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad3')


        else

            grad1_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 1, worker%itime, 'grad1', ME)
            grad1_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 2, worker%itime, 'grad1', ME)
            grad1_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 3, worker%itime, 'grad1', ME)
            grad1_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 4, worker%itime, 'grad1', ME)

            grad2_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 1, worker%itime, 'grad2', ME)
            grad2_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 2, worker%itime, 'grad2', ME)
            grad2_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 3, worker%itime, 'grad2', ME)
            grad2_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 4, worker%itime, 'grad2', ME)

            grad3_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 1, worker%itime, 'grad3', ME)
            grad3_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 2, worker%itime, 'grad3', ME)
            grad3_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 3, worker%itime, 'grad3', ME)
            grad3_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, worker%iface, 4, worker%itime, 'grad3', ME)

        end if

        !
        ! Account for cylindrical. Get tangential momentum from angular momentum.
        ! Also convert derivatives from derivatives of angular momentum to tangential.
        !
        ! We want:
        !       (rho * u_theta)  instead of      (r * rho * u_theta)
        !   grad(rho * u_theta)  instead of  grad(r * rho * u_theta)
        !
        !   grad(rho * u_theta) = grad(r * rho * u_theta)/r  -  grad(r)(rho*u_theta)/r
        !
        ! Where grad(r) = [1,0,0]
        !
        if (worker%coordinate_system() == 'Cylindrical') then
            r = worker%coordinate('1')
            mom2       = mom2 / r
            grad1_mom2 = (grad1_mom2/r) - mom2/r
            grad2_mom2 = (grad2_mom2/r)
            grad3_mom2 = (grad3_mom2/r)
        end if

        v1 = mom1/density
        v2 = mom2/density
        v3 = mom3/density

        ! interior velocity gradient
        grad1_v1 = -(v1/density)*grad1_density  +  (ONE/density)*grad1_mom1
        grad2_v1 = -(v1/density)*grad2_density  +  (ONE/density)*grad2_mom1
        grad3_v1 = -(v1/density)*grad3_density  +  (ONE/density)*grad3_mom1

        grad1_v2 = -(v2/density)*grad1_density  +  (ONE/density)*grad1_mom2
        grad2_v2 = -(v2/density)*grad2_density  +  (ONE/density)*grad2_mom2
        grad3_v2 = -(v2/density)*grad3_density  +  (ONE/density)*grad3_mom2

        grad1_v3 = -(v3/density)*grad1_density  +  (ONE/density)*grad1_mom3
        grad2_v3 = -(v3/density)*grad2_density  +  (ONE/density)*grad2_mom3
        grad3_v3 = -(v3/density)*grad3_density  +  (ONE/density)*grad3_mom3


    end subroutine compute_velocity_gradient
    !******************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/6/2018
    !!
    !------------------------------------------------------------------------------
    subroutine compute_density_gradient(worker,grad1_density, grad2_density, grad3_density) 
        type(chidg_worker_t),                   intent(inout)   :: worker
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad1_density
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad2_density
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad3_density

        if (worker%interpolation_source == 'element') then
            grad1_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad1')
            grad2_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad2')
            grad3_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad3')
        else
            grad1_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface, 1, worker%itime, 'grad1', ME)
            grad2_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface, 1, worker%itime, 'grad2', ME)
            grad3_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface, 1, worker%itime, 'grad3', ME)
        end if


    end subroutine compute_density_gradient
    !******************************************************************************






    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/13/2018
    !!
    !------------------------------------------------------------------------------
    function compute_local_residual_density(self,worker,bc_comm,density_modes,p_avg,c_avg,density_avg, M1_avg, M2_avg, M3_avg) result(R_modes)
        class(outlet_neumann_LODI_localdg_t),           intent(inout)               :: self
        type(chidg_worker_t),                           intent(inout)               :: worker
        type(mpi_comm),                                 intent(in)                  :: bc_comm
        type(AD_D),                                     intent(inout), allocatable  :: density_modes(:)
        type(AD_D),                                     intent(in)                  :: p_avg
        type(AD_D),                                     intent(in)                  :: c_avg
        type(AD_D),                                     intent(in)                  :: density_avg
        type(AD_D),                                     intent(in)                  :: M1_avg
        type(AD_D),                                     intent(in)                  :: M2_avg
        type(AD_D),                                     intent(in)                  :: M3_avg

        type(AD_D), allocatable, dimension(:)   ::                          &
            density_sigma,  grad1_density_sigma,  grad2_density_sigma,  grad3_density_sigma,  &
            grad1_p_m,   grad2_p_m,      grad3_p_m,                         &
            lift_face_1,    lift_face_2,    lift_face_3,                    &
            lift_elem_1,    lift_elem_2,    lift_elem_3,                    &
            diff_1,         diff_2,         diff_3,     diff,               &
            face_array, element_array, R_modes, integral, integrand, flux1, flux2, flux3,   &
            density_m, mom1_m, mom2_m, mom3_m, energy_m,                                    &
            grad1_density_LODI, grad2_density_LODI, grad3_density_LODI, gradn_density_LODI, &
            grad1_v1_m, grad2_v1_m, grad3_v1_m,                 &
            grad1_v2_m, grad2_v2_m, grad3_v2_m,                 &
            grad1_v3_m, grad2_v3_m, grad3_v3_m,                 &
            grad1_density_m, grad2_density_m, grad3_density_m,  &
            gradn_vn, gradn_p, gradn_density,                   &
            v1_m, v2_m, v3_m, c_m, vn, L1, L2, L5, lambda1, lambda2, lambda5, T1, p_m

        integer(ik) :: iface, iface_bc, idomain_l, ielement_l, i

        real(rk),   allocatable, dimension(:) :: p_avg_user, r

        ! Store index of bc face
        iface_bc = worker%iface

        density_m = worker%get_field('Density',    'value', 'face interior')
        mom1_m    = worker%get_field('Momentum-1', 'value', 'face interior')
        mom2_m    = worker%get_field('Momentum-2', 'value', 'face interior')
        mom3_m    = worker%get_field('Momentum-3', 'value', 'face interior')
        energy_m  = worker%get_field('Energy',     'value', 'face interior')
        p_m       = worker%get_field('Pressure',   'value', 'face interior')

        v1_m = mom1_m/density_m
        v2_m = mom2_m/density_m
        v3_m = mom3_m/density_m

        ! Get user parameter settings
        p_avg_user = self%bcproperties%compute('Average Pressure',         worker%time(),worker%coords())

        worker%interpolation_source = 'face interior'
        call compute_density_gradient(worker,grad1_density_m,grad2_density_m,grad3_density_m)
        call compute_velocity_gradient(worker,grad1_v1_m,grad2_v1_m,grad3_v1_m, &
                                              grad1_v2_m,grad2_v2_m,grad3_v2_m, &
                                              grad1_v3_m,grad2_v3_m,grad3_v3_m)
        call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)

        
        ! Compute normal pressure gradients
        gradn_p = grad1_p_m*worker%unit_normal(1) + grad2_p_m*worker%unit_normal(2) + grad3_p_m*worker%unit_normal(3)

        ! Compute gradient of normal velocity in the normal direction
        gradn_vn = (grad1_v1_m*worker%unit_normal(1) + grad1_v2_m*worker%unit_normal(2) + grad1_v3_m*worker%unit_normal(3))*worker%unit_normal(1) + &
                   (grad2_v1_m*worker%unit_normal(1) + grad2_v2_m*worker%unit_normal(2) + grad2_v3_m*worker%unit_normal(3))*worker%unit_normal(2) + &
                   (grad3_v1_m*worker%unit_normal(1) + grad3_v2_m*worker%unit_normal(2) + grad3_v3_m*worker%unit_normal(3))*worker%unit_normal(3)
        gradn_vn = grad1_v1_m

        ! Compute gradient of density in normal direction
        gradn_density = grad1_density_m*worker%unit_normal(1) + grad2_density_m*worker%unit_normal(2) + grad3_density_m*worker%unit_normal(3)

        ! Compute wave amplitudes
        vn = v1_m*worker%unit_normal(1) + v2_m*worker%unit_normal(2) + v3_m*worker%unit_normal(3)
        vn = v1_m
        c_m = sqrt(gam*p_m/density_m)
        lambda1 = vn-c_m
        lambda2 = vn
        lambda5 = vn+c_m
        L1 = lambda1*(gradn_p - density_m*c_m*gradn_vn)
        L2 = lambda2*(c_m*c_m*gradn_density - gradn_p)
        L5 = lambda5*(gradn_p + density_m*c_m*gradn_vn)
        ! Recompute L1
        L1(:) = 50000._rk*(p_avg - p_avg_user(1))

        T1 = ( (v2_m*grad2_p_m + v3_m*grad3_p_m)    &
               + gam*p_m*(grad2_v2_m + grad3_v3_m)  &
               - density_m*c_m*(v2_m*grad2_v1_m + v3_m*grad3_v1_m) )

        do i = 1,size(T1)
            T1(i) = 0.0*(M1_avg-ONE)*T1(i)
        end do
        L5 = -L5
        L1 = -L1
        T1 = -T1
        L2 = -L2

        gradn_density_LODI = (ONE/(c_m*c_m))*(L2/vn  +  HALF*(L5/(vn+c_m) + (L1+T1)/(vn-c_m)))
        grad1_density_LODI = gradn_density_LODI*worker%unit_normal(1)
        grad2_density_LODI = gradn_density_LODI*worker%unit_normal(2)
        grad3_density_LODI = gradn_density_LODI*worker%unit_normal(3)

        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Initialize face/element array sizes
        face_array    = worker%get_field('Pressure','value','face interior')
        element_array = worker%get_field('Pressure','value','element')
        face_array    = ZERO
        element_array = ZERO

        ! Initialize R_modes storage
        R_modes = density_modes
        R_modes = ZERO

        ! Initialize p at quadrature nodes to zero
        lift_elem_1 = element_array
        lift_elem_2 = element_array
        lift_elem_3 = element_array

        ! Accumulate FACE residuals
        do iface = 1,NFACES

            lift_face_1 = face_array
            lift_face_2 = face_array
            lift_face_3 = face_array

            worker%iface = iface
            worker%interpolation_source = 'face interior'

            ! Get sigma
            density_m = worker%get_field('Density','value','face interior')
            mom1_m = worker%get_field('Momentum-1','value','face interior')
            mom2_m = worker%get_field('Momentum-2','value','face interior')
            mom3_m = worker%get_field('Momentum-3','value','face interior')
            v1_m = mom1_m/density_m
            v2_m = mom2_m/density_m
            v3_m = mom3_m/density_m
            vn = v1_m*worker%unit_normal(1) + v2_m*worker%unit_normal(2) + v3_m*worker%unit_normal(3)
            p_m = worker%get_field('Pressure','value','face interior')
            c_m = sqrt(gam*p_m/density_m)
            call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)
            call compute_density_gradient(worker,grad1_density_m,grad2_density_m,grad3_density_m)

            associate ( weights  => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface),                        &
                        br2_face => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_face,                                     &
                        br2_vol  => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_vol,                                      &
                        val      => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface),     &
                        grad1    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad1,                                        &
                        grad2    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad2,                                        &
                        grad3    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad3,                                        &
                        valtrans => transpose(worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface)) )

            ! INTERIOR FACE
            if (iface /= iface_bc) then
                ! Take boundary state from interior original problem
                density_sigma       = matmul(val,  density_modes)
                grad1_density_sigma = matmul(grad1,density_modes)
                grad2_density_sigma = matmul(grad2,density_modes)
                grad3_density_sigma = matmul(grad3,density_modes)

                diff = (density_m - density_sigma)

            ! BOUNDARY FACE
            else
                ! boundary pressure: extrapolating interior and adding average update.
                ! boundary pressure gradient: set to user-specified values
                density_sigma = matmul(val, density_modes)
                
                grad1_density_sigma = grad1_density_LODI
                grad2_density_sigma = grad2_density_LODI
                grad3_density_sigma = grad3_density_LODI

                diff = (HALF/(c_m*c_m))*L1/(vn-c_m)
                diff = ZERO

            end if

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            diff_1 = diff * weights * worker%normal(1)
            diff_2 = diff * weights * worker%normal(2)
            diff_3 = diff * weights * worker%normal(3)

            ! Compute lift at face gq nodes
            lift_face_1 = matmul(br2_face,diff_1)
            lift_face_2 = matmul(br2_face,diff_2)
            lift_face_3 = matmul(br2_face,diff_3)
        
            ! Accumulate face lift to element gq nodes
            lift_elem_1 = lift_elem_1 + matmul(br2_vol,diff_1)
            lift_elem_2 = lift_elem_2 + matmul(br2_vol,diff_2)
            lift_elem_3 = lift_elem_3 + matmul(br2_vol,diff_3)

            ! Penalize gradient with lift
            grad1_density_sigma = grad1_density_sigma  +  lift_face_1
            grad2_density_sigma = grad2_density_sigma  +  lift_face_2
            grad3_density_sigma = grad3_density_sigma  +  lift_face_3

            integrand = weights*( (grad1_density_sigma-grad1_density_m)*worker%normal(1) +  &
                                  (grad2_density_sigma-grad2_density_m)*worker%normal(2) +  &
                                  (grad3_density_sigma-grad3_density_m)*worker%normal(3) )

            integral = matmul(valtrans,integrand)

            ! Accumulate residual from face
            R_modes = R_modes  +  integral

            end associate
        end do

        associate ( weights     => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_element(),               &
                    jinv        => worker%mesh%domain(idomain_l)%elems(ielement_l)%jinv,                                    & 
                    grad1       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1,                                   &
                    grad2       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2,                                   &
                    grad3       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3,                                   &
                    grad1_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1_trans,                             &
                    grad2_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2_trans,                             &
                    grad3_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3_trans )

        ! Accumulate ELEMENT residuals
        worker%iface = 1
        worker%interpolation_source = 'element'


        ! Get sigma
        call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)
        call compute_density_gradient(worker,grad1_density_m,grad2_density_m,grad3_density_m)

        ! Get grad_p
        grad1_density_sigma = matmul(grad1, density_modes)
        grad2_density_sigma = matmul(grad2, density_modes)
        grad3_density_sigma = matmul(grad3, density_modes)

        ! Penalize grad_p with boundary lift
        grad1_density_sigma = grad1_density_sigma + lift_elem_1
        grad2_density_sigma = grad2_density_sigma + lift_elem_2
        grad3_density_sigma = grad3_density_sigma + lift_elem_3

        flux1 = (grad1_density_sigma - grad1_density_m)*weights*jinv
        flux2 = (grad2_density_sigma - grad2_density_m)*weights*jinv
        flux3 = (grad3_density_sigma - grad3_density_m)*weights*jinv

        integral = matmul(grad1_trans, flux1) + &
                   matmul(grad2_trans, flux2) + &
                   matmul(grad3_trans, flux3) 

        R_modes = R_modes - integral

        end associate

        ! Reset iface_bc
        call worker%set_face(iface_bc)

    end function compute_local_residual_density
    !******************************************************************************




    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/13/2018
    !!
    !------------------------------------------------------------------------------
    function compute_local_residual_pressure(self,worker,bc_comm,p_modes,p_avg,c_avg,density_avg, M1_avg, M2_avg, M3_avg) result(R_modes)
        class(outlet_neumann_LODI_localdg_t),  intent(inout)               :: self
        type(chidg_worker_t),                           intent(inout)               :: worker
        type(mpi_comm),                                 intent(in)                  :: bc_comm
        type(AD_D),                                     intent(inout), allocatable  :: p_modes(:)
        type(AD_D),                                     intent(in)                  :: p_avg
        type(AD_D),                                     intent(in)                  :: c_avg
        type(AD_D),                                     intent(in)                  :: density_avg
        type(AD_D),                                     intent(in)                  :: M1_avg
        type(AD_D),                                     intent(in)                  :: M2_avg
        type(AD_D),                                     intent(in)                  :: M3_avg

        type(AD_D), allocatable, dimension(:)   ::                          &
            p_sigma,        grad1_p_sigma,  grad2_p_sigma,  grad3_p_sigma,  &
            p, grad1_p_m,   grad2_p_m,      grad3_p_m,                      &
            lift_face_1,    lift_face_2,    lift_face_3,                    &
            lift_elem_1,    lift_elem_2,    lift_elem_3,                    &
            diff_1,         diff_2,         diff_3,     diff,               &
            face_array, element_array, R_modes, integral, integrand, flux1, flux2, flux3,   &
            density_m, mom1_m, mom2_m, mom3_m, energy_m,                                    &
            grad1_p_LODI, grad2_p_LODI, grad3_p_LODI, gradn_p_LODI, grad1_phi4,             &
            grad1_v1_m, grad2_v1_m, grad3_v1_m,                 &
            grad1_v2_m, grad2_v2_m, grad3_v2_m,                 &
            grad1_v3_m, grad2_v3_m, grad3_v3_m,                 &
            grad1_density_m, grad2_density_m, grad3_density_m,  &
            gradn_vn, gradn_p, gradn_density,                   &
            v1_m, v2_m, v3_m, c_m, vn, L1, L2, L5, lambda1, lambda2, lambda5, T1, p_m

        integer(ik) :: iface, iface_bc, idomain_l, ielement_l, i

        real(rk),   allocatable, dimension(:) :: p_avg_user, r


        ! Store index of bc face
        iface_bc = worker%iface

        density_m = worker%get_field('Density',    'value', 'face interior')
        mom1_m    = worker%get_field('Momentum-1', 'value', 'face interior')
        mom2_m    = worker%get_field('Momentum-2', 'value', 'face interior')
        mom3_m    = worker%get_field('Momentum-3', 'value', 'face interior')
        energy_m  = worker%get_field('Energy',     'value', 'face interior')
        p_m       = worker%get_field('Pressure',   'value', 'face interior')

        v1_m = mom1_m/density_m
        v2_m = mom2_m/density_m
        v3_m = mom3_m/density_m

        ! Get user parameter settings
        p_avg_user = self%bcproperties%compute('Average Pressure',         worker%time(),worker%coords())

        !print*, 'Average Pressure: ', p_avg%x_ad_

        worker%interpolation_source = 'face interior'
        call compute_density_gradient(worker,grad1_density_m,grad2_density_m,grad3_density_m)
        call compute_velocity_gradient(worker,grad1_v1_m,grad2_v1_m,grad3_v1_m, &
                                              grad1_v2_m,grad2_v2_m,grad3_v2_m, &
                                              grad1_v3_m,grad2_v3_m,grad3_v3_m)
        call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)

        
        ! Compute normal pressure gradients
        gradn_p = grad1_p_m*worker%unit_normal(1) + grad2_p_m*worker%unit_normal(2) + grad3_p_m*worker%unit_normal(3)

        ! Compute gradient of normal velocity in the normal direction
        gradn_vn = (grad1_v1_m*worker%unit_normal(1) + grad1_v2_m*worker%unit_normal(2) + grad1_v3_m*worker%unit_normal(3))*worker%unit_normal(1) + &
                   (grad2_v1_m*worker%unit_normal(1) + grad2_v2_m*worker%unit_normal(2) + grad2_v3_m*worker%unit_normal(3))*worker%unit_normal(2) + &
                   (grad3_v1_m*worker%unit_normal(1) + grad3_v2_m*worker%unit_normal(2) + grad3_v3_m*worker%unit_normal(3))*worker%unit_normal(3)
        gradn_vn = grad1_v1_m

        ! Compute gradient of density in normal direction
        gradn_density = grad1_density_m*worker%unit_normal(1) + grad2_density_m*worker%unit_normal(2) + grad3_density_m*worker%unit_normal(3)

        ! Compute wave amplitudes
        vn = v1_m*worker%unit_normal(1) + v2_m*worker%unit_normal(2) + v3_m*worker%unit_normal(3)
        vn = v1_m
        c_m = sqrt(gam*p_m/density_m)
        lambda1 = vn-c_m
        lambda2 = vn
        lambda5 = vn+c_m
        L1 = lambda1*(gradn_p - density_m*c_m*gradn_vn)
        L2 = lambda2*(c_m*c_m*gradn_density - gradn_p)
        L5 = lambda5*(gradn_p + density_m*c_m*gradn_vn)
        ! Recompute L1
        L1(:) = 50000._rk*(p_avg - p_avg_user(1))

        T1 = ( (v2_m*grad2_p_m + v3_m*grad3_p_m)    &
               + gam*p_m*(grad2_v2_m + grad3_v3_m)  &
               - density_m*c_m*(v2_m*grad2_v1_m + v3_m*grad3_v1_m) )

        do i = 1,size(T1)
            T1(i) = 0.0*(M1_avg-ONE)*T1(i)
        end do
        L5 = -L5
        L1 = -L1
        T1 = -T1
        L2 = -L2

        gradn_p_LODI = HALF*(L5/(vn+c_m)  +  (L1+T1)/(vn-c_m))
        grad1_p_LODI = gradn_p_LODI*worker%unit_normal(1)
        grad2_p_LODI = gradn_p_LODI*worker%unit_normal(2)
        grad3_p_LODI = gradn_p_LODI*worker%unit_normal(3)

        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Initialize face/element array sizes
        face_array    = worker%get_field('Pressure','value','face interior')
        element_array = worker%get_field('Pressure','value','element')
        face_array    = ZERO
        element_array = ZERO

        ! Initialize R_modes storage
        R_modes = p_modes
        R_modes = ZERO

        ! Initialize p at quadrature nodes to zero
        lift_elem_1 = element_array
        lift_elem_2 = element_array
        lift_elem_3 = element_array

        ! Accumulate FACE residuals
        do iface = 1,NFACES

            lift_face_1 = face_array
            lift_face_2 = face_array
            lift_face_3 = face_array

            worker%iface = iface
            worker%interpolation_source = 'face interior'

            ! Get sigma
            density_m = worker%get_field('Density','value','face interior')
            mom1_m = worker%get_field('Momentum-1','value','face interior')
            mom2_m = worker%get_field('Momentum-2','value','face interior')
            mom3_m = worker%get_field('Momentum-3','value','face interior')
            v1_m = mom1_m/density_m
            v2_m = mom2_m/density_m
            v3_m = mom3_m/density_m
            vn = v1_m*worker%unit_normal(1,iface_bc) + v2_m*worker%unit_normal(2,iface_bc) + v3_m*worker%unit_normal(3,iface_bc)
            vn = v1_m
            p_m = worker%get_field('Pressure','value','face interior')
            c_m = sqrt(gam*p_m/density_m)
            call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)

            associate ( weights  => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface),                        &
                        br2_face => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_face,                                     &
                        br2_vol  => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_vol,                                      &
                        val      => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface),     &
                        grad1    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad1,                                        &
                        grad2    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad2,                                        &
                        grad3    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad3,                                        &
                        valtrans => transpose(worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface)) )

            ! INTERIOR FACE
            if (iface /= iface_bc) then
                ! Take boundary state from interior original problem
                p_sigma       = matmul(val,  p_modes)
                grad1_p_sigma = matmul(grad1,p_modes)
                grad2_p_sigma = matmul(grad2,p_modes)
                grad3_p_sigma = matmul(grad3,p_modes)

                diff = (p_m - p_sigma)

            ! BOUNDARY FACE
            else
                ! boundary pressure: extrapolating interior and adding average update.
                ! boundary pressure gradient: set to user-specified values
                p_sigma = matmul(val, p_modes)
                
                grad1_p_sigma = grad1_p_LODI
                grad2_p_sigma = grad2_p_LODI
                grad3_p_sigma = grad3_p_LODI

                diff = HALF*(L1)/(vn-c_m)
                diff = ZERO

            end if

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            diff_1 = diff * weights * worker%normal(1)
            diff_2 = diff * weights * worker%normal(2)
            diff_3 = diff * weights * worker%normal(3)

            ! Compute lift at face gq nodes
            lift_face_1 = matmul(br2_face,diff_1)
            lift_face_2 = matmul(br2_face,diff_2)
            lift_face_3 = matmul(br2_face,diff_3)
        
            ! Accumulate face lift to element gq nodes
            lift_elem_1 = lift_elem_1 + matmul(br2_vol,diff_1)
            lift_elem_2 = lift_elem_2 + matmul(br2_vol,diff_2)
            lift_elem_3 = lift_elem_3 + matmul(br2_vol,diff_3)

            ! Penalize gradient with lift
            grad1_p_sigma = grad1_p_sigma  +  lift_face_1
            grad2_p_sigma = grad2_p_sigma  +  lift_face_2
            grad3_p_sigma = grad3_p_sigma  +  lift_face_3

            integrand = weights*( (grad1_p_sigma-grad1_p_m)*worker%normal(1) +  &
                                  (grad2_p_sigma-grad2_p_m)*worker%normal(2) +  &
                                  (grad3_p_sigma-grad3_p_m)*worker%normal(3) )

            integral = matmul(valtrans,integrand)

            ! Accumulate residual from face
            R_modes = R_modes  +  integral

            end associate
        end do

        associate ( weights     => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_element(),               &
                    jinv        => worker%mesh%domain(idomain_l)%elems(ielement_l)%jinv,                                    & 
                    grad1       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1,                                   &
                    grad2       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2,                                   &
                    grad3       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3,                                   &
                    grad1_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1_trans,                             &
                    grad2_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2_trans,                             &
                    grad3_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3_trans )

        ! Accumulate ELEMENT residuals
        worker%iface = 1
        worker%interpolation_source = 'element'

        ! Get sigma
        call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)

        ! Get grad_p
        grad1_p_sigma = matmul(grad1, p_modes)
        grad2_p_sigma = matmul(grad2, p_modes)
        grad3_p_sigma = matmul(grad3, p_modes)

        ! Penalize grad_p with boundary lift
        grad1_p_sigma = grad1_p_sigma + lift_elem_1
        grad2_p_sigma = grad2_p_sigma + lift_elem_2
        grad3_p_sigma = grad3_p_sigma + lift_elem_3

        flux1 = (grad1_p_sigma - grad1_p_m)*weights*jinv
        flux2 = (grad2_p_sigma - grad2_p_m)*weights*jinv
        flux3 = (grad3_p_sigma - grad3_p_m)*weights*jinv

        integral = matmul(grad1_trans, flux1) + &
                   matmul(grad2_trans, flux2) + &
                   matmul(grad3_trans, flux3) 

        R_modes = R_modes - integral

        end associate

        ! Reset iface_bc
        call worker%set_face(iface_bc)

    end function compute_local_residual_pressure
    !******************************************************************************







    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/13/2018
    !!
    !------------------------------------------------------------------------------
    function compute_local_residual_vn(self,worker,bc_comm,vn_modes,p_avg,c_avg,density_avg, M1_avg, M2_avg, M3_avg) result(R_modes)
        class(outlet_neumann_LODI_localdg_t),  intent(inout)               :: self
        type(chidg_worker_t),                           intent(inout)               :: worker
        type(mpi_comm),                                 intent(in)                  :: bc_comm
        type(AD_D),                                     intent(inout), allocatable  :: vn_modes(:)
        type(AD_D),                                     intent(in)                  :: p_avg
        type(AD_D),                                     intent(in)                  :: c_avg
        type(AD_D),                                     intent(in)                  :: density_avg
        type(AD_D),                                     intent(in)                  :: M1_avg
        type(AD_D),                                     intent(in)                  :: M2_avg
        type(AD_D),                                     intent(in)                  :: M3_avg

        type(AD_D), allocatable, dimension(:)   ::                          &
            vn_sigma,        grad1_vn_sigma,  grad2_vn_sigma,  grad3_vn_sigma,  &
            vn, grad1_vn_m,   grad2_vn_m,      grad3_vn_m,                      &
            lift_face_1,    lift_face_2,    lift_face_3,                    &
            lift_elem_1,    lift_elem_2,    lift_elem_3,                    &
            diff_1,         diff_2,         diff_3,     diff,               &
            face_array, element_array, R_modes, integral, integrand, flux1, flux2, flux3,   &
            density_m, mom1_m, mom2_m, mom3_m, energy_m,                                    &
            grad1_vn_LODI, grad2_vn_LODI, grad3_vn_LODI, gradn_vn_LODI,                     &
            grad1_p_m,  grad2_p_m,  grad3_p_m,                  &
            grad1_v1_m, grad2_v1_m, grad3_v1_m,                 &
            grad1_v2_m, grad2_v2_m, grad3_v2_m,                 &
            grad1_v3_m, grad2_v3_m, grad3_v3_m,                 &
            grad1_density_m, grad2_density_m, grad3_density_m,  &
            gradn_vn, gradn_p, gradn_density,                   &
            v1_m, v2_m, v3_m, c_m, L1, L2, L5, lambda1, lambda2, lambda5, T1, p_m

        integer(ik) :: iface, iface_bc, idomain_l, ielement_l, i

        real(rk),   allocatable, dimension(:) :: p_avg_user, r, n1, n2, n3

        ! Store index of bc face
        iface_bc = worker%iface

        p_avg_user   = self%bcproperties%compute('Average Pressure',         worker%time(),worker%coords())

        density_m = worker%get_field('Density',    'value', 'face interior')
        mom1_m    = worker%get_field('Momentum-1', 'value', 'face interior')
        mom2_m    = worker%get_field('Momentum-2', 'value', 'face interior')
        mom3_m    = worker%get_field('Momentum-3', 'value', 'face interior')
        energy_m  = worker%get_field('Energy',     'value', 'face interior')
        p_m       = worker%get_field('Pressure',   'value', 'face interior')

        v1_m = mom1_m/density_m
        v2_m = mom2_m/density_m
        v3_m = mom3_m/density_m

        worker%interpolation_source = 'face interior'
        call compute_density_gradient(worker,grad1_density_m,grad2_density_m,grad3_density_m)

        call compute_velocity_gradient(worker,grad1_v1_m,grad2_v1_m,grad3_v1_m, &
                                              grad1_v2_m,grad2_v2_m,grad3_v2_m, &
                                              grad1_v3_m,grad2_v3_m,grad3_v3_m)

        call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)

        
        ! Compute normal pressure gradients
        gradn_p = grad1_p_m*worker%unit_normal(1) + grad2_p_m*worker%unit_normal(2) + grad3_p_m*worker%unit_normal(3)

        ! Compute gradient of normal velocity in the normal direction
        gradn_vn = (grad1_v1_m*worker%unit_normal(1) + grad1_v2_m*worker%unit_normal(2) + grad1_v3_m*worker%unit_normal(3))*worker%unit_normal(1) + &
                   (grad2_v1_m*worker%unit_normal(1) + grad2_v2_m*worker%unit_normal(2) + grad2_v3_m*worker%unit_normal(3))*worker%unit_normal(2) + &
                   (grad3_v1_m*worker%unit_normal(1) + grad3_v2_m*worker%unit_normal(2) + grad3_v3_m*worker%unit_normal(3))*worker%unit_normal(3)
        gradn_vn = grad1_v1_m

        ! Compute gradient of density in normal direction
        gradn_density = grad1_density_m*worker%unit_normal(1) + grad2_density_m*worker%unit_normal(2) + grad3_density_m*worker%unit_normal(3)

        ! Compute wave amplitudes
        vn = v1_m*worker%unit_normal(1) + v2_m*worker%unit_normal(2) + v3_m*worker%unit_normal(3)
        vn = v1_m
        c_m = sqrt(gam*p_m/density_m)
        lambda1 = vn-c_m
        lambda2 = vn
        lambda5 = vn+c_m
        L1 = lambda1*(gradn_p - density_m*c_m*gradn_vn)
        L2 = lambda2*(c_m*c_m*gradn_density - gradn_p)
        L5 = lambda5*(gradn_p + density_m*c_m*gradn_vn)
        ! Recompute L1
        L1(:) = 50000._rk*(p_avg - p_avg_user(1))

        T1 = ( (v2_m*grad2_p_m + v3_m*grad3_p_m)    &
               + gam*p_m*(grad2_v2_m + grad3_v3_m)  &
               - density_m*c_m*(v2_m*grad2_v1_m + v3_m*grad3_v1_m) )

        do i = 1,size(T1)
            T1(i) = 1.0*(M1_avg-ONE)*T1(i)
        end do
        !L5 = -L5
        !L1 = -L1
        !T1 = -T1
        !L2 = -L2

        gradn_vn_LODI = (HALF/(density_m*c_m))*((L5)/(vn+c_m) - (L1+T1)/(vn-c_m))
        grad1_vn_LODI = gradn_vn_LODI*worker%unit_normal(1)
        grad2_vn_LODI = gradn_vn_LODI*worker%unit_normal(2)
        grad3_vn_LODI = gradn_vn_LODI*worker%unit_normal(3)

        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Initialize face/element array sizes
        face_array    = worker%get_field('Pressure','value','face interior')
        element_array = worker%get_field('Pressure','value','element')
        face_array    = ZERO
        element_array = ZERO

        ! Initialize R_modes storage
        R_modes = vn_modes
        R_modes = ZERO

        ! Initialize p at quadrature nodes to zero
        lift_elem_1 = element_array
        lift_elem_2 = element_array
        lift_elem_3 = element_array

        ! Accumulate FACE residuals
        do iface = 1,NFACES

            lift_face_1 = face_array
            lift_face_2 = face_array
            lift_face_3 = face_array

            worker%iface = iface
            worker%interpolation_source = 'face interior'

            ! Get sigma
            density_m = worker%get_field('Density',    'value', 'face interior')
            mom1_m    = worker%get_field('Momentum-1', 'value', 'face interior')
            mom2_m    = worker%get_field('Momentum-2', 'value', 'face interior')
            mom3_m    = worker%get_field('Momentum-3', 'value', 'face interior')
            p_m = worker%get_field('Pressure','value','face interior')
            c_m = sqrt(gam*p_m/density_m)
            v1_m = mom1_m/density_m
            v2_m = mom2_m/density_m
            v3_m = mom3_m/density_m

            n1 = worker%unit_normal(1,iface_bc)
            n2 = worker%unit_normal(2,iface_bc)
            n3 = worker%unit_normal(3,iface_bc)
            vn = v1_m*n1(1) + v2_m*n2(1) + v3_m*n3(1)
            vn = v1_m

            call compute_pressure_gradient(worker,grad1_p_m,grad2_p_m,grad3_p_m)
            call compute_velocity_gradient(worker,grad1_v1_m,grad2_v1_m,grad3_v1_m, &
                                                  grad1_v2_m,grad2_v2_m,grad3_v2_m, &
                                                  grad1_v3_m,grad2_v3_m,grad3_v3_m)
            gradn_vn = (grad1_v1_m*n1(1) + grad1_v2_m*n2(1) + grad1_v3_m*n3(1))*n1(1) + &
                       (grad2_v1_m*n1(1) + grad2_v2_m*n2(1) + grad2_v3_m*n3(1))*n2(1) + &
                       (grad3_v1_m*n1(1) + grad3_v2_m*n2(1) + grad3_v3_m*n3(1))*n3(1)
            grad1_vn_m = gradn_vn*n1(1)
            grad2_vn_m = gradn_vn*n2(1)
            grad3_vn_m = gradn_vn*n3(1)
            grad1_vn_m = grad1_v1_m
            grad2_vn_m = grad2_v1_m
            grad3_vn_m = grad3_v1_m


            associate ( weights  => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface),                        &
                        br2_face => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_face,                                     &
                        br2_vol  => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_vol,                                      &
                        val      => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface),     &
                        grad1    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad1,                                        &
                        grad2    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad2,                                        &
                        grad3    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad3,                                        &
                        valtrans => transpose(worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface)) )

            ! INTERIOR FACE
            if (iface /= iface_bc) then
                ! Take boundary state from interior original problem
                vn_sigma       = matmul(val,  vn_modes)
                grad1_vn_sigma = matmul(grad1,vn_modes)
                grad2_vn_sigma = matmul(grad2,vn_modes)
                grad3_vn_sigma = matmul(grad3,vn_modes)

                diff = (vn - vn_sigma)

            ! BOUNDARY FACE
            else
                ! boundary pressure: extrapolating interior and adding average update.
                ! boundary pressure gradient: set to user-specified values
                vn_sigma = matmul(val, vn_modes)
                
                grad1_vn_sigma = grad1_vn_LODI
                grad2_vn_sigma = grad2_vn_LODI
                grad3_vn_sigma = grad3_vn_LODI

                diff = -(HALF/(density_m*c_m))*L1/(vn-c_m)
                diff = ZERO

            end if

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            diff_1 = diff * weights * worker%normal(1)
            diff_2 = diff * weights * worker%normal(2)
            diff_3 = diff * weights * worker%normal(3)

            ! Compute lift at face gq nodes
            lift_face_1 = matmul(br2_face,diff_1)
            lift_face_2 = matmul(br2_face,diff_2)
            lift_face_3 = matmul(br2_face,diff_3)
        
            ! Accumulate face lift to element gq nodes
            lift_elem_1 = lift_elem_1 + matmul(br2_vol,diff_1)
            lift_elem_2 = lift_elem_2 + matmul(br2_vol,diff_2)
            lift_elem_3 = lift_elem_3 + matmul(br2_vol,diff_3)

            ! Penalize gradient with lift
            grad1_vn_sigma = grad1_vn_sigma  +  lift_face_1
            grad2_vn_sigma = grad2_vn_sigma  +  lift_face_2
            grad3_vn_sigma = grad3_vn_sigma  +  lift_face_3

            integrand = weights*( (grad1_vn_sigma-grad1_vn_m)*worker%normal(1) +  &
                                  (grad2_vn_sigma-grad2_vn_m)*worker%normal(2) +  &
                                  (grad3_vn_sigma-grad3_vn_m)*worker%normal(3) )

            integral = matmul(valtrans,integrand)

            ! Accumulate residual from face
            R_modes = R_modes  +  integral

            end associate
        end do

        associate ( weights     => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_element(),               &
                    jinv        => worker%mesh%domain(idomain_l)%elems(ielement_l)%jinv,                                    & 
                    grad1       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1,                                   &
                    grad2       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2,                                   &
                    grad3       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3,                                   &
                    grad1_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1_trans,                             &
                    grad2_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2_trans,                             &
                    grad3_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3_trans )

        ! Accumulate ELEMENT residuals
        worker%iface = 1
        worker%interpolation_source = 'element'


        ! Compute gradient of normal velocity in the normal direction
        call compute_velocity_gradient(worker,grad1_v1_m,grad2_v1_m,grad3_v1_m, &
                                              grad1_v2_m,grad2_v2_m,grad3_v2_m, &
                                              grad1_v3_m,grad2_v3_m,grad3_v3_m)
        n1 = worker%unit_normal(1,iface_bc)
        n2 = worker%unit_normal(2,iface_bc)
        n3 = worker%unit_normal(3,iface_bc)
        gradn_vn = (grad1_v1_m*n1(1) + grad1_v2_m*n2(1) + grad1_v3_m*n3(1))*n1(1) + &
                   (grad2_v1_m*n1(1) + grad2_v2_m*n2(1) + grad2_v3_m*n3(1))*n2(1) + &
                   (grad3_v1_m*n1(1) + grad3_v2_m*n2(1) + grad3_v3_m*n3(1))*n3(1)
        
        grad1_vn_m = gradn_vn*n1(1)
        grad2_vn_m = gradn_vn*n2(1)
        grad3_vn_m = gradn_vn*n3(1)
        grad1_vn_m = grad1_v1_m
        grad2_vn_m = grad2_v1_m
        grad3_vn_m = grad3_v1_m


        ! Get grad_p
        grad1_vn_sigma = matmul(grad1, vn_modes)
        grad2_vn_sigma = matmul(grad2, vn_modes)
        grad3_vn_sigma = matmul(grad3, vn_modes)

        ! Penalize grad_p with boundary lift
        grad1_vn_sigma = grad1_vn_sigma + lift_elem_1
        grad2_vn_sigma = grad2_vn_sigma + lift_elem_2
        grad3_vn_sigma = grad3_vn_sigma + lift_elem_3

        
        flux1 = (grad1_vn_sigma - grad1_vn_m)*weights*jinv
        flux2 = (grad2_vn_sigma - grad2_vn_m)*weights*jinv
        flux3 = (grad3_vn_sigma - grad3_vn_m)*weights*jinv

        integral = matmul(grad1_trans, flux1) + &
                   matmul(grad2_trans, flux2) + &
                   matmul(grad3_trans, flux3) 

        R_modes = R_modes - integral

        end associate

        ! Reset iface_bc
        call worker%set_face(iface_bc)

    end function compute_local_residual_vn
    !******************************************************************************





    !>  Newton solver
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/13/2018
    !!
    !------------------------------------------------------------------------------
    subroutine converge_local_problem_pressure(self,worker,bc_comm,p_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        class(outlet_neumann_LODI_localdg_t),  intent(inout)               :: self
        type(chidg_worker_t),                           intent(inout)               :: worker
        type(mpi_comm),                                 intent(in)                  :: bc_comm
        type(AD_D),                                     intent(inout), allocatable  :: p_modes(:)
        type(AD_D),                                     intent(in)                  :: p_avg
        type(AD_D),                                     intent(in)                  :: c_avg
        type(AD_D),                                     intent(in)                  :: density_avg
        type(AD_D),                                     intent(in)                  :: M1_avg
        type(AD_D),                                     intent(in)                  :: M2_avg
        type(AD_D),                                     intent(in)                  :: M3_avg

        type(AD_D), allocatable, dimension(:)   ::  &
            R_modes, zero_face, dp

        real(rk)    :: tol, resid
        integer(ik) :: nterms_s, idomain_l, ielement_l, ierr

        ! Get element location
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Initialize emptry array with derivatives allocated
        zero_face = worker%get_field('Density','value','face interior')
        zero_face = ZERO

        ! Initialize p_modes storage with derivatives
        nterms_s = worker%mesh%domain(idomain_l)%elems(ielement_l)%nterms_s
        allocate(p_modes(nterms_s), stat=ierr)
        if (ierr /= 0) call AllocationError
        p_modes(:) = zero_face(1)
        if (size(p_modes) /= nterms_s) call chidg_signal(FATAL,'outlet_neumann_LODI_localdg: converge_p Error 1.')

        resid = huge(1._rk)
        tol = 1.e-3_rk
        R_modes = self%compute_local_residual_pressure(worker,bc_comm,p_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        do while (resid > tol)

            ! Move R to right-hand side
            R_modes = (-ONE)*R_modes

            ! Solve linear system: bc was precomputed from init_bc_local_problem
            dp = matmul(worker%mesh%domain(idomain_l)%elems(ielement_l)%bc,R_modes)

            ! Apply update
            p_modes = p_modes + dp

            ! Test residual
            R_modes = self%compute_local_residual_pressure(worker,bc_comm,p_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
            resid = norm2(R_modes(:)%x_ad_)
            if (resid > 1.e10_rk) call chidg_signal(FATAL,"outlet_neumann_LODI_localdg: element-local problem diverged.")

        end do

    end subroutine converge_local_problem_pressure
    !******************************************************************************





    !>  Newton solver
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/13/2018
    !!
    !------------------------------------------------------------------------------
    subroutine converge_local_problem_vn(self,worker,bc_comm,vn_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        class(outlet_neumann_LODI_localdg_t),  intent(inout)               :: self
        type(chidg_worker_t),                           intent(inout)               :: worker
        type(mpi_comm),                                 intent(in)                  :: bc_comm
        type(AD_D),                                     intent(inout), allocatable  :: vn_modes(:)
        type(AD_D),                                     intent(in)                  :: p_avg
        type(AD_D),                                     intent(in)                  :: c_avg
        type(AD_D),                                     intent(in)                  :: density_avg
        type(AD_D),                                     intent(in)                  :: M1_avg
        type(AD_D),                                     intent(in)                  :: M2_avg
        type(AD_D),                                     intent(in)                  :: M3_avg

        type(AD_D), allocatable, dimension(:)   ::  &
            R_modes, zero_face, dv

        real(rk)    :: tol, resid
        integer(ik) :: nterms_s, idomain_l, ielement_l, ierr

        ! Get element location
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Initialize emptry array with derivatives allocated
        zero_face = worker%get_field('Density','value','face interior')
        zero_face = ZERO

        ! Initialize vn_modes storage with derivatives
        nterms_s = worker%mesh%domain(idomain_l)%elems(ielement_l)%nterms_s
        allocate(vn_modes(nterms_s), stat=ierr)
        if (ierr /= 0) call AllocationError
        vn_modes(:) = zero_face(1)
        if (size(vn_modes) /= nterms_s) call chidg_signal(FATAL,'outlet_neumann_LODI_localdg: converge_p Error 1.')

        resid = huge(1._rk)
        tol = 1.e-5_rk
        R_modes = self%compute_local_residual_vn(worker,bc_comm,vn_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        do while (resid > tol)

            ! Move R to right-hand side
            R_modes = (-ONE)*R_modes

            ! Solve linear system: bc was precomputed from init_bc_local_problem
            dv = matmul(worker%mesh%domain(idomain_l)%elems(ielement_l)%bc,R_modes)

            ! Apply update
            vn_modes = vn_modes + dv

            ! Test residual
            R_modes = self%compute_local_residual_vn(worker,bc_comm,vn_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
            resid = norm2(R_modes(:)%x_ad_)
            if (resid > 1.e10_rk) call chidg_signal(FATAL,"outlet_neumann_LODI_localdg: element-local problem diverged.")

        end do

    end subroutine converge_local_problem_vn
    !******************************************************************************




    !>  Newton solver
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/13/2018
    !!
    !------------------------------------------------------------------------------
    subroutine converge_local_problem_density(self,worker,bc_comm,density_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        class(outlet_neumann_LODI_localdg_t),  intent(inout)               :: self
        type(chidg_worker_t),                           intent(inout)               :: worker
        type(mpi_comm),                                 intent(in)                  :: bc_comm
        type(AD_D),                                     intent(inout), allocatable  :: density_modes(:)
        type(AD_D),                                     intent(in)                  :: p_avg
        type(AD_D),                                     intent(in)                  :: c_avg
        type(AD_D),                                     intent(in)                  :: density_avg
        type(AD_D),                                     intent(in)                  :: M1_avg
        type(AD_D),                                     intent(in)                  :: M2_avg
        type(AD_D),                                     intent(in)                  :: M3_avg

        type(AD_D), allocatable, dimension(:)   ::  &
            R_modes, zero_face, ddensity

        real(rk)    :: tol, resid
        integer(ik) :: nterms_s, idomain_l, ielement_l, ierr

        ! Get element location
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Initialize emptry array with derivatives allocated
        zero_face = worker%get_field('Density','value','face interior')
        zero_face = ZERO

        ! Initialize density_modes storage with derivatives
        nterms_s = worker%mesh%domain(idomain_l)%elems(ielement_l)%nterms_s
        allocate(density_modes(nterms_s), stat=ierr)
        if (ierr /= 0) call AllocationError
        density_modes(:) = zero_face(1)
        if (size(density_modes) /= nterms_s) call chidg_signal(FATAL,'outlet_neumann_LODI_localdg: converge_p Error 1.')

        resid = huge(1._rk)
        tol = 1.e-8_rk
        R_modes = self%compute_local_residual_density(worker,bc_comm,density_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
        do while (resid > tol)

            ! Move R to right-hand side
            R_modes = (-ONE)*R_modes

            ! Solve linear system: bc was precomputed from init_bc_local_problem
            ddensity = matmul(worker%mesh%domain(idomain_l)%elems(ielement_l)%bc,R_modes)

            ! Apply update
            density_modes = density_modes + ddensity

            ! Test residual
            R_modes = self%compute_local_residual_density(worker,bc_comm,density_modes,p_avg,c_avg,density_avg,M1_avg,M2_avg,M3_avg)
            resid = norm2(R_modes(:)%x_ad_)
            if (resid > 1.e10_rk) call chidg_signal(FATAL,"outlet_neumann_LODI_localdg: element-local problem diverged.")

        end do

    end subroutine converge_local_problem_density
    !******************************************************************************














end module bc_state_outlet_neumann_LODI_localdg
