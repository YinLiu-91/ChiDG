module bc_state_tm_extrapolate
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO, ONE, HALF
    use type_bc_state,          only: bc_state_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use type_point,             only: point_t
    use mpi_f08,                only: mpi_comm
    use DNAD_D
    implicit none


    !> Extrapolation boundary condition 
    !!      - Extrapolate interior variables to be used for calculating the boundary flux.
    !!  
    !!  @author Nathan A. Wukie
    !!  @date   1/31/2016
    !!
    !----------------------------------------------------------------------------------------
    type, public, extends(bc_state_t) :: tm_extrapolate_t

    contains

        procedure   :: init                 !< Set-up bc state with options/name etc.
        procedure   :: compute_bc_state     !< boundary condition function implementation

    end type tm_extrapolate_t
    !****************************************************************************************




contains



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/29/2016
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(tm_extrapolate_t),   intent(inout) :: self
        
        !
        ! Set operator name
        !
        call self%set_name("TM Extrapolate")
        call self%set_family("Symmetry")


    end subroutine init
    !********************************************************************************





    !> Specialized compute routine for Extrapolation Boundary Condition
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/3/2016
    !!
    !!  @param[in]      mesh    Mesh data containing elements and faces for the domain
    !!  @param[inout]   sdata   Solver data containing solution vector, rhs, linearization, etc.
    !!  @param[inout]   prop    properties_t object containing equations and material_t objects
    !!  @param[in]      face    face_info_t containing indices on location and misc information
    !!  @param[in]      flux    function_into_t containing info on the function being computed
    !!
    !-------------------------------------------------------------------------------------------
    subroutine compute_bc_state(self,worker,prop,bc_COMM)
        class(tm_extrapolate_t),   intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        class(properties_t),        intent(inout)   :: prop
        type(mpi_comm),             intent(in)      :: bc_COMM


        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:)   ::  &
            p_m, grad1_p_m, grad2_p_m, grad3_p_m



        !
        ! Interpolate interior solution to face quadrature nodes
        !
        p_m       = worker%get_field('Pressure', 'value', 'face interior')
        grad1_p_m = worker%get_field('Pressure', 'grad1', 'face interior')
        grad2_p_m = worker%get_field('Pressure', 'grad2', 'face interior')
        grad3_p_m = worker%get_field('Pressure', 'grad3', 'face interior')




        !
        ! Store boundary condition state
        !
        call worker%store_bc_state("Pressure", p_m,       'value')
        call worker%store_bc_state("Pressure", grad1_p_m, 'grad1')
        call worker%store_bc_state("Pressure", grad2_p_m, 'grad2')
        call worker%store_bc_state("Pressure", grad3_p_m, 'grad3')



    end subroutine compute_bc_state
    !**********************************************************************************************






end module bc_state_tm_extrapolate
