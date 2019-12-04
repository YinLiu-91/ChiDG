!>  Compute
!!
!!  @author Nathan A. Wukie (AFRL)
!!  @date   7/12/2017
!!  @note   Modified directly from 'chidg airfoil' action
!!
!!
!---------------------------------------------------------------------------------------------
module mod_force
#include <messenger.h>
    use mod_kinds,              only: rk, ik
    use mod_constants,          only: ZERO, TWO, NO_ID, NO_DIFF
    use mod_chidg_mpi,          only: ChiDG_COMM
    use type_chidg_data,        only: chidg_data_t
    use type_element_info,      only: element_info_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_chidg_cache,       only: chidg_cache_t
    use type_cache_handler,     only: cache_handler_t
    use mpi_f08,                only: MPI_AllReduce, MPI_REAL8, MPI_SUM
    use ieee_arithmetic,        only: ieee_is_nan
    use DNAD_D
    implicit none







contains



    !>  Compute force integrated over a specified patch group.
    !!
    !!
    !!  F = int[ (tau-p) dot n ] dPatch
    !!
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   7/12/2017
    !!  @note   Modified directly from 'chidg airfoil' action
    !!
    !!
    !!  @param[in]      data            chidg_data instance
    !!  @param[in]      patch_group     Name of patch group over which the force will be integrated.
    !!  @result[out]    force           Integrated force vector: force = [f1, f2, f3]
    !!
    !-----------------------------------------------------------------------------------
    subroutine report_forces(data,patch_group,force,power)
        type(chidg_data_t), intent(inout)               :: data
        character(*),       intent(in)                  :: patch_group
        real(rk),           intent(inout),  optional    :: force(3)
        real(rk),           intent(inout),  optional    :: power
    
        integer(ik)                 :: group_ID, patch_ID, face_ID, &
                                       idomain_l, ielement_l, iface, ierr

        type(chidg_worker_t)        :: worker
        type(chidg_cache_t)         :: cache
        type(cache_handler_t)       :: cache_handler
        type(element_info_t)        :: elem_info


        real(rk)                                ::  &
            force_local(3), power_local


        real(rk),   allocatable, dimension(:)   ::  &
            norm_1,      norm_2,      norm_3,       &
            norm_1_phys, norm_2_phys, norm_3_phys,  &
            weights, det_jacobian_grid

        real(rk),   allocatable                 ::  &
            jacobian_grid(:,:,:), grid_velocity(:,:)


        type(AD_D), allocatable, dimension(:)   ::  &
            tau_11,     tau_12,     tau_13,         &
            tau_21,     tau_22,     tau_23,         &
            tau_31,     tau_32,     tau_33,         &
            stress_x,   stress_y,   stress_z,       &
            pressure


        call write_line('Computing Force...', io_proc=GLOBAL_MASTER)


        ! Initialize Chidg Worker references
        call worker%init(data%mesh, data%eqnset(:)%prop, data%sdata, data%time_manager, cache)


        ! Get patch_group boundary group ID
        group_ID = data%mesh%get_bc_patch_group_id(trim(patch_group))


        ! Make sure q is assembled so it doesn't hang when triggered in get_field
        call data%sdata%q%assemble()

        ! Loop over domains/elements/faces for "patch_group" 
        force_local = ZERO
        power_local = ZERO

        if (group_ID /= NO_ID) then
            do patch_ID = 1,data%mesh%bc_patch_group(group_ID)%npatches()
                do face_ID = 1,data%mesh%bc_patch_group(group_ID)%patch(patch_ID)%nfaces()

                    idomain_l  = data%mesh%bc_patch_group(group_ID)%patch(patch_ID)%idomain_l()
                    ielement_l = data%mesh%bc_patch_group(group_ID)%patch(patch_ID)%ielement_l(face_ID)
                    iface      = data%mesh%bc_patch_group(group_ID)%patch(patch_ID)%iface(face_ID)


                    ! Initialize element location object
                    elem_info = data%mesh%get_element_info(idomain_l,ielement_l)
                    call worker%set_element(elem_info)
                    worker%itime = 1


                    ! Update the element cache and all models so they are available
                    call cache_handler%update(worker,data%eqnset,data%bc_state_group, components    = 'all',   &
                                                                                      face          = NO_ID,   &
                                                                                      differentiate = NO_DIFF, &
                                                                                      lift          = .true.)


                    call worker%set_face(iface)


                    ! Get pressure
                    if (worker%check_field_exists('Pressure')) then
                        pressure = worker%get_field('Pressure', 'value', 'boundary')
                    else
                        if (patch_ID == 1) call write_line('NOTE: Pressure not found in equation set, setting to zero.',io_proc=GLOBAL_MASTER)
                        pressure = ZERO*worker%get_field('Density', 'value', 'boundary')
                    end if

                    ! Get shear stress tensor
                    if (worker%check_field_exists('Shear-11')) then
                        tau_11 = worker%get_field('Shear-11', 'value', 'boundary')
                        tau_22 = worker%get_field('Shear-22', 'value', 'boundary')
                        tau_33 = worker%get_field('Shear-33', 'value', 'boundary')
                        tau_12 = worker%get_field('Shear-12', 'value', 'boundary')
                        tau_13 = worker%get_field('Shear-13', 'value', 'boundary')
                        tau_23 = worker%get_field('Shear-23', 'value', 'boundary')
                    else
                        if (patch_ID == 1) call write_line('NOTE: Shear-## not found in equation set, setting to zero.',io_proc=GLOBAL_MASTER)
                        tau_11 = ZERO*worker%get_field('Density', 'value', 'boundary')
                        tau_22 = ZERO*worker%get_field('Density', 'value', 'boundary')
                        tau_33 = ZERO*worker%get_field('Density', 'value', 'boundary')
                        tau_12 = ZERO*worker%get_field('Density', 'value', 'boundary')
                        tau_13 = ZERO*worker%get_field('Density', 'value', 'boundary')
                        tau_23 = ZERO*worker%get_field('Density', 'value', 'boundary')
                    end if


                    ! From symmetry
                    tau_21 = tau_12
                    tau_31 = tau_13
                    tau_32 = tau_23

                    ! Add pressure component
                    tau_11 = tau_11 - pressure
                    tau_22 = tau_22 - pressure
                    tau_33 = tau_33 - pressure


                    ! Get normal vectors and reverse, because we want outward-facing vector from
                    ! the geometry.
                    norm_1  = -worker%normal(1)
                    norm_2  = -worker%normal(2)
                    norm_3  = -worker%normal(3)


                    ! Transform normal vector with g*G^{-T} so our normal and Area correspond to quantities on the deformed grid
                    det_jacobian_grid = worker%get_det_jacobian_grid_face('value', 'face interior')
                    jacobian_grid     = worker%get_inv_jacobian_grid_face('face interior')
                    grid_velocity     = worker%get_grid_velocity_face('face interior')
                    norm_1_phys = det_jacobian_grid*(jacobian_grid(1,1,:)*norm_1 + jacobian_grid(2,1,:)*norm_2 + jacobian_grid(3,1,:)*norm_3)
                    norm_2_phys = det_jacobian_grid*(jacobian_grid(1,2,:)*norm_1 + jacobian_grid(2,2,:)*norm_2 + jacobian_grid(3,2,:)*norm_3)
                    norm_3_phys = det_jacobian_grid*(jacobian_grid(1,3,:)*norm_1 + jacobian_grid(2,3,:)*norm_2 + jacobian_grid(3,3,:)*norm_3)

                    !norm_1_phys = -worker%unit_normal_ale(1)
                    !norm_2_phys = -worker%unit_normal_ale(2)
                    !norm_3_phys = -worker%unit_normal_ale(3)
                    ! But then need to add area scaling
                    

                    ! Compute \vector{n} dot \tensor{tau}
                    !   : These should produce the same result since the tensor is 
                    !   : symmetric. Not sure which is more correct.
                    !
                    !stress_x = norm_1_phys*tau_11 + norm_2_phys*tau_21 + norm_3_phys*tau_31
                    !stress_y = norm_1_phys*tau_12 + norm_2_phys*tau_22 + norm_3_phys*tau_32
                    !stress_z = norm_1_phys*tau_13 + norm_2_phys*tau_23 + norm_3_phys*tau_33


                    stress_x = tau_11*norm_1_phys + tau_12*norm_2_phys + tau_13*norm_3_phys
                    stress_y = tau_21*norm_1_phys + tau_22*norm_2_phys + tau_23*norm_3_phys
                    stress_z = tau_31*norm_1_phys + tau_32*norm_2_phys + tau_33*norm_3_phys


                    ! Integrate
                    weights = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%weights_face(iface)

                    if (present(force)) then
                        force_local(1) = force_local(1) + sum( stress_x(:)%x_ad_ * weights)
                        force_local(2) = force_local(2) + sum( stress_y(:)%x_ad_ * weights)
                        force_local(3) = force_local(3) + sum( stress_z(:)%x_ad_ * weights)
                    end if

                    if (present(power)) then
                        power_local = power_local + sum( (stress_x(:)%x_ad_ * grid_velocity(:,1) * weights) + &
                                                         (stress_y(:)%x_ad_ * grid_velocity(:,2) * weights) + &
                                                         (stress_z(:)%x_ad_ * grid_velocity(:,3) * weights) )
                    end if

                end do !iface
            end do !ipatch
        end if ! group_ID /= NO_ID


        ! Reduce result across processors
        if (present(force)) call MPI_AllReduce(force_local,force,3,MPI_REAL8,MPI_SUM,ChiDG_COMM,ierr)
        if (present(power)) call MPI_AllReduce(power_local,power,1,MPI_REAL8,MPI_SUM,ChiDG_COMM,ierr)


    end subroutine report_forces
    !******************************************************************************************


    



end module mod_force
