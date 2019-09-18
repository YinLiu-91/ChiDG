module PRIMLINEULER_volume_advective_sourceterms_real
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: NFACES,ONE,TWO,FOUR,HALF,ZERO

    use type_volume_flux,       only: volume_flux_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
!    use type_mesh,              only: mesh_t
!    use type_solverdata,        only: solverdata_t
!    use type_element_info,      only: element_info_t
!    use type_function_info,     only: function_info_t
!    
!    use mod_interpolate,        only: interpolate
!    use mod_integrate,          only: integrate_volume_source
    use DNAD_D

    use PRIMLINEULER_properties,    only: PRIMLINEULER_properties_t
    implicit none

    private


    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/17/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    type, extends(volume_flux_t), public :: PRIMLINEULER_volume_advective_sourceterms_real_t


    contains

        procedure  :: compute
        
    end type PRIMLINEULER_volume_advective_sourceterms_real_t
    !*****************************************************************************************










contains



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/17/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine compute(self,worker,prop)
        class(PRIMLINEULER_volume_advective_sourceterms_real_t),    intent(in)      :: self
        type(chidg_worker_t),                                       intent(inout)   :: worker
        class(properties_t),                                        intent(inout)   :: prop

        ! Equation indices
        integer(ik)    :: irho_r,  irho_i
        integer(ik)    :: iu_r,    iu_i
        integer(ik)    :: iv_r,    iv_i
        integer(ik)    :: iw_r,    iw_i
        integer(ik)    :: ip_r,    ip_i

        real(rk)       :: gam, alpha, eps
        real(rk)       :: x, y, x0, y0
        integer(ik)    :: igq



        type(AD_D), allocatable, dimension(:)   ::  &
                    rho_r, u_r, v_r, w_r, p_r, H,   &
                    flux




        !
        ! Get equation indices
        !
        irho_r = prop%get_eqn_index("rho_r")
        iu_r   = prop%get_eqn_index("u_r")
        iv_r   = prop%get_eqn_index("v_r")
        iw_r   = prop%get_eqn_index("w_r")
        ip_r   = prop%get_eqn_index("p_r")

        irho_i = prop%get_eqn_index("rho_i")
        iu_i   = prop%get_eqn_index("u_i")
        iv_i   = prop%get_eqn_index("v_i")
        iw_i   = prop%get_eqn_index("w_i")
        ip_i   = prop%get_eqn_index("p_i")



        !
        ! Interpolate solution to quadrature nodes
        !
        rho_r = worker%interpolate(irho_r, 'value')
        u_r   = worker%interpolate(iu_r, 'value')
        v_r   = worker%interpolate(iv_r, 'value')
        w_r   = worker%interpolate(iw_r, 'value')
        p_r   = worker%interpolate(ip_r, 'value')


!        rho_r = interpolate(mesh,sdata%q,elem_info,function_info,irho_r, 'value')
!        u_r   = interpolate(mesh,sdata%q,elem_info,function_info,iu_r,   'value')
!        v_r   = interpolate(mesh,sdata%q,elem_info,function_info,iv_r,   'value')
!        w_r   = interpolate(mesh,sdata%q,elem_info,function_info,iw_r,   'value')
!        p_r   = interpolate(mesh,sdata%q,elem_info,function_info,ip_r,   'value')


        ! Initialize flux derivative storage
        flux = rho_r
        flux = ZERO

!        !===========================
!        !        MASS FLUX
!        !===========================
!        x0 = ZERO
!        y0 = ZERO
!
!        eps = 
!
!        do igq = 1,size(rho_r)
!            x = mesh(idom)%elems(ielem)%quad_pts(igq)%c1_
!            y = mesh(idom)%elems(ielem)%quad_pts(igq)%c2_
!
!            flux(igq) = eps * exp(-(LOG(TWO)/TWO) * ((x-x0)**TWO + (y-y0)**TWO)/(0.2_rk**TWO) )
!
!        end do
!
!
!        call integrate_volume_source(mesh(idom)%elems(ielem),sdata,idom,irho_i,iblk,flux)
!
!
!        !===========================
!        !     X-MOMENTUM FLUX
!        !===========================
!        eps = ZERO
!        do igq = 1,size(rho)
!            x = mesh(idom)%elems(ielem)%quad_pts(igq)%c1_
!            y = mesh(idom)%elems(ielem)%quad_pts(igq)%c2_
!
!            flux(igq) = eps * exp(-alpha * (x**TWO + y**TWO) )
!
!        end do
!        flux = ZERO
!
!        call integrate_volume_source(mesh(idom)%elems(ielem),sdata,idom,irhou_r,iblk,flux)
!
!
!        !============================
!        !     Y-MOMENTUM FLUX
!        !============================
!        eps = ZERO
!        do igq = 1,size(rho)
!            x = mesh(idom)%elems(ielem)%quad_pts(igq)%c1_
!            y = mesh(idom)%elems(ielem)%quad_pts(igq)%c2_
!
!            flux(igq) = eps * exp(-alpha * (x**TWO + y**TWO) )
!
!        end do
!        flux = ZERO
!
!        call integrate_volume_source(mesh(idom)%elems(ielem),sdata,idom,irhov_r,iblk,flux)
!
!!        !============================
!!        !     Z-MOMENTUM FLUX
!!        !============================
!!        flux_x = (rhow*rhou)/rho
!!        flux_y = (rhow*rhov)/rho
!!        flux_z = (rhow*rhow)/rho  +  p
!!
!!        call integrate_volume_flux(mesh(idom)%elems(ielem),sdata,idom,irhow,iblk,flux_x,flux_y,flux_z)
!!
!        !============================
!        !       ENERGY FLUX
!        !============================
!        x0 = ZERO
!        y0 = ZERO
!        !eps = 429.8837052_rk
!        eps = 171.9534821_rk
!
!        do igq = 1,size(rho_r)
!            x = mesh(idom)%elems(ielem)%quad_pts(igq)%c1_
!            y = mesh(idom)%elems(ielem)%quad_pts(igq)%c2_
!
!            ! Multi-geometry scattering
!            !flux(igq) = eps * exp(-LOG(TWO) * ((x-x0)**TWO + (y-y0)**TWO)/(0.2_rk**TWO) )
!
!            ! Monopole
!            flux(igq) = eps * exp(-(LOG(TWO)/TWO) * ((x-x0)**TWO + (y-y0)**TWO)/(0.2_rk**TWO) )
!
!        end do
!
!        !call integrate_volume_source(mesh(idom)%elems(ielem),sdata,idom,ip_r,iblk,flux)
!        call integrate_volume_source(mesh(idom)%elems(ielem),sdata,idom,ip_i,iblk,flux)

    end subroutine compute
    !**********************************************************************************************************






end module PRIMLINEULER_volume_advective_sourceterms_real
