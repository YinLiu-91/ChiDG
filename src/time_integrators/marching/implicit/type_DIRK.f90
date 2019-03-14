!>  Implementation of a three-stage, diagonally-implicit runge-kutta 
!!  time integrator, DIRK.
!!
!!  Object definitions:
!!  -------------------
!!      1: DIRK_t                       the new time_integrator_t itself. Defines how to take a
!!                                      DIRK step.
!!      2: assemble_DIRK_t              a system_assembler_t object that implements how to assemble
!!                                      the spatio-temporal discrete system. This gets passed
!!                                      to the nonlinear solver. The nonlinear solver can then 
!!                                      call assemble without having to know anything about
!!                                      the system itself.
!!      3: DIRK_solver_controller_t     a solver_controller_t object that implements rules
!!                                      governing the behaviour of nonlinear and linear solvers.
!!                                      It implements rules for when to update the lhs matrix
!!                                      and also when to update the preconditioner.
!!
!!  Subroutines:
!!  ------------
!!  The subroutines defined are just implementations of the methods for the objects
!!  above and implement the described behaviors that then get attached to the objects.
!!
!!
!!  @author Mayank Sharma
!!  @author Nathan A. Wukie (AFRL)
!!  
!!
!------------------------------------------------------------------------------------
module type_DIRK
#include<messenger.h>
    use messenger,                      only: write_line
    use mod_kinds,                      only: rk, ik
    use mod_constants,                  only: ZERO, ONE, TWO, THREE, FOUR, FIVE, SIX, SEVEN, NO_ID
    use mod_spatial,                    only: update_space
!    use mod_update_grid,                only: update_grid
    use mod_io,                         only: verbosity, backend
    use mod_force,                      only: report_aerodynamics

    use type_time_integrator_marching,  only: time_integrator_marching_t
    use type_system_assembler,          only: system_assembler_t

    use type_chidg_data,                only: chidg_data_t
    use type_chidg_matrix,              only: chidg_matrix_t
    use type_nonlinear_solver,          only: nonlinear_solver_t           
    use type_linear_solver,             only: linear_solver_t
    use type_preconditioner,            only: preconditioner_t
    use type_solver_controller,         only: solver_controller_t
    use type_chidg_vector
    implicit none
    private


    !>  Object implementing the diagonally implicit RK time integrator
    !!
    !!  @author Mayank Sharma
    !!  @date   5/20/2017
    !!
    !--------------------------------------------------------------------------------
    type, extends(time_integrator_marching_t),  public      :: DIRK_t


    contains

        procedure   :: init
        procedure   :: step


    end type DIRK_t
    !********************************************************************************




    !>  Object for assembling the implicit system
    !!
    !!  @author Mayank Sharma
    !!  @date   5/20/2017
    !!
    !--------------------------------------------------------------------------------
    type, extends(system_assembler_t),  public      :: assemble_DIRK_t

        type(chidg_vector_t)    :: q_n
        type(chidg_vector_t)    :: q_n_stage

    contains

        procedure   :: assemble

    end type assemble_DIRK_t
    !********************************************************************************





    !>  Control the lhs update inside the nonlinear solver.
    !!
    !!  Reference:
    !!  Persson, P.-O., "High-Order Navier-Stokes Simulations using a Sparse 
    !!  Line-Based Discontinuous Galerkin Method", AIAA-2012-0456
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/22/2017
    !!
    !--------------------------------------------------------------------------------
    type, extends(solver_controller_t), public :: DIRK_solver_controller_t

    contains

        procedure   :: update_lhs

    end type DIRK_solver_controller_t
    !********************************************************************************







    !
    ! DIRK butcher tableau coefficients
    !
    real(rk),   parameter   :: alpha = 0.435866521508459_rk
    real(rk),   parameter   :: tau   = (ONE + alpha)/TWO
    real(rk),   parameter   :: b1    = -(SIX*(alpha*alpha) - (16._rk*alpha) + ONE)/FOUR
    real(rk),   parameter   :: b2    = (SIX*(alpha*alpha) - (20._rk*alpha) + FIVE)/FOUR



contains




    !>  Initialize the DIRK_t time integrator
    !!
    !!  Create the assembler and atatch it to the time_integrator object so it can 
    !!  be passed to the nonlinear solver
    !!
    !!  @author Mayank Sharma
    !!  @date   5/20/2017
    !!
    !-----------------------------------------------------------------------------------
    subroutine init(self)
        class(DIRK_t),          intent(inout)   :: self

        integer(ik)             :: ierr
        type(assemble_DIRK_t)   :: assemble_DIRK

        call self%set_name('DIRK')

        if (allocated(self%system)) deallocate(self%system)
        allocate(self%system, source=assemble_DIRK, stat=ierr)
        if (ierr /= 0) call AllocationError


    end subroutine init
    !***********************************************************************************




    !>  Solution advancement via the diagonally implicit Runge-Kutta method
    !!
    !!  Given the system of partial differential equations consisting of the time derivative of the 
    !!  solution vector and a spatial residual as
    !!
    !!  M \frac{\partial R(Q)}{\partial Q} + R(Q) = 0 
    !!
    !!  the solution is advanced in time as
    !!
    !!  Q^{n + 1} = Q^{n} + b_{1}\Delta Q_{1} + b_{2}\Delta Q_{2} + b_{3}\Delta Q_{3}
    !!
    !!  The implicit system is obtained as
    !!
    !!  \frac{\Delta Q_{i}}{\Delta t}M = -R(Q^{n} + \sum_{j = 1}^{i}A_{ij}|Delta Q_{j})  for i = 1,3 
    !! 
    !!  where b_{i}, A_{ij} are the coefficients of the DIRK method. The Newton linearization 
    !!  of the above system is obtained as
    !!
    !!  (M + \alpha\Delta t\frac{\partial R(Q_{i}^{m})}{\partial Q})\delta Q_{i}^{m} = 
    !!      -M\Delta Q_{i}^{m} - \Delta t R(Q_{i}^{m})  for i = 1,3 
    !!
    !!  with 
    !!  Q_{i}^{m} = Q^{n} + \sum_{j = 1}^{i}A_{ij}Q){j} + \alpha \Delta Q_{i}^{m} 
    !!  \delta Q_{i}^{m} = \Delta Q_{i}^{m + 1} - \Delta Q_{i}^{m} 
    !!
    !!  @author Mayank Sharma
    !!  @date   5/20/2017
    !!
    !---------------------------------------------------------------------------------------
    subroutine step(self,data,nonlinear_solver,linear_solver,preconditioner)
        class(DIRK_t),                          intent(inout)   :: self
        type(chidg_data_t),                     intent(inout)   :: data
        class(nonlinear_solver_t),  optional,   intent(inout)   :: nonlinear_solver
        class(linear_solver_t),     optional,   intent(inout)   :: linear_solver
        class(preconditioner_t),    optional,   intent(inout)   :: preconditioner

        integer(ik),    parameter   :: nstage = 3
        type(chidg_vector_t)        :: dq(nstage), q_temp, q_n, residual
        real(rk)                    :: t_n, force(3), work
        real(rk),   allocatable     :: elem_field(:)
        integer(ik)                 :: istage, myunit, idom, ielem, ifield
        logical                     :: exists

        type(DIRK_solver_controller_t),    save    :: solver_controller



!        !
!        ! Report to file.
!        !
!        call report_aerodynamics(data,'Airfoil',force=force, work=work)
!        if (IRANK == GLOBAL_MASTER) then
!            inquire(file="aero.txt", exist=exists)
!            if (exists) then
!                open(newunit=myunit, file="aero.txt", status="old", position="append",action="write")
!            else
!                open(newunit=myunit, file="aero.txt", status="new",action="write")
!                write(myunit,*) 'force-1', 'force-2', 'force-3', 'work'
!            end if
!            write(myunit,*) force(1), force(2), force(3), work
!            close(myunit)
!        end if
!
!



        !
        ! Store solution at nth time step to a separate vector for use in this subroutine
        ! Store the time at the current time step
        !
        q_n = data%sdata%q
        t_n = data%time_manager%t

        select type(associate_name => self%system)
            type is (assemble_DIRK_t)
                associate_name%q_n = data%sdata%q
        end select


        ! Initialize update vector array
        do istage = 1, nstage
            dq(istage) = chidg_vector(trim(backend))
            call dq(istage)%init(data%mesh, data%time_manager%ntime)
            call dq(istage)%set_ntime(data%time_manager%ntime)
            call dq(istage)%clear()
        end do


        associate ( q  => data%sdata%q,        &
                    dt => data%time_manager%dt )
            
            do istage = 1, nstage

                ! For each stage, compute the assembly variables
                ! Also compute the time as \f$ t = t_{n} + c_{i}*dt \f$ at the current stage
                ! The correct time is needed for time-varying boundary conditions
                select case(istage)
                    case(1)
                        select type(an => self%system)
                            type is (assemble_DIRK_t)
                                an%q_n_stage = chidg_vector(trim(backend))
                                call an%q_n_stage%init(data%mesh,data%time_manager%ntime)
                                call an%q_n_stage%set_ntime(data%time_manager%ntime)
                                call an%q_n_stage%clear()
                        end select

                        q_temp = q_n
                        data%time_manager%t = t_n + alpha*dt

                    case(2)
                        select type(an => self%system)
                            type is (assemble_DIRK_t)
                                an%q_n_stage = (tau - alpha)*dq(1)
                        end select

                        q_temp = q_n + (tau - alpha)*dq(1)
                        data%time_manager%t = t_n + tau*dt

                    case(3)
                        select type(an => self%system)
                            type is (assemble_DIRK_t)
                                an%q_n_stage = b1*dq(1) + b2*dq(2)
                        end select

                        q_temp = q_n + b1*dq(1) + b2*dq(2)
                        data%time_manager%t = t_n + dt

                end select

                ! Solve assembled nonlinear system, the nonlinear update is the stagewise update
                ! System assembled in subroutine assemble
                !
                !call update_grid(data)
                call data%update_grid()
                call nonlinear_solver%solve(data,self%system,linear_solver,preconditioner,solver_controller)


                ! Store stagewise update
                dq(istage) = (q - q_temp)/alpha

            end do


            ! Store end residual(change in solution)
            residual = q - q_n
            call self%residual_norm%push_back( residual%norm(ChiDG_COMM) )

        end associate

    end subroutine step
   !***************************************************************************************




    !>  Assemble the system for the DIRK equations with temporal contributons
    !!
    !!  @author Mayank Sharma
    !!  @date   5/20/2017
    !!
    !!  \f$ lhs = \frac{\partial R(Qi_{i})}{\partial Q} \f$
    !!  \f$ rhs = R(Q_{i}) \f$
    !!  \f$ M = element mass matrix \f$
    !!
    !!  For system assembly with temporal contributions
    !!
    !!  \f$ lhs = \frac{M}{\alpha dt} + lhs \f$
    !!  \f$ rhs = \frac{M \Delta Q_{i}}{dt} + rhs \f$
    !!
    !-------------------------------------------------------------------------------------
    subroutine assemble(self,data,differentiate,timing)
        class(assemble_DIRK_t), intent(inout)               :: self
        type(chidg_data_t),     intent(inout)               :: data
        logical,                intent(in)                  :: differentiate
        real(rk),               intent(inout),  optional    :: timing

        type(chidg_vector_t)        :: delta_q 
        type(element_info_t)        :: elem_info
        real(rk)                    :: dt
        integer(ik)                 :: itime, idom, ielem, ifield, ierr
        real(rk),   allocatable     :: mat(:,:), values(:)

        associate( q   => data%sdata%q,   &
                   dq  => data%sdata%dq,  &
                   lhs => data%sdata%lhs, & 
                   rhs => data%sdata%rhs)

        ! Clear data containers
        call rhs%clear()
        if (differentiate) call lhs%clear()
        
        ! Get spatial update
        call update_space(data,differentiate,timing)

        ! Get no. of time levels (=1 for time marching) and time step
        dt    = data%time_manager%dt

        
        ! Compute \f$ \Delta Q^{m}_{i}\f$
        ! Used to assemble rhs
        delta_q = chidg_vector(trim(backend))
        call delta_q%init(data%mesh,data%time_manager%ntime)
        call delta_q%set_ntime(data%time_manager%ntime)
        call delta_q%clear()
        call delta_q%assemble()
        delta_q = (q - self%q_n - self%q_n_stage)/alpha


        ! Add mass/dt to sub-block diagonal in dR/dQ
        do idom = 1,data%mesh%ndomains()
            do ielem = 1,data%mesh%domain(idom)%nelem
                elem_info = data%mesh%get_element_info(idom,ielem)
                do itime = 1,data%mesh%domain(idom)%ntime
                    do ifield = 1,data%eqnset(elem_info%eqn_ID)%prop%nprimary_fields()

                        ! Add time derivative to left-hand side
                        mat = data%mesh%domain(idom)%elems(ielem)%mass / (alpha*dt)
                        if (differentiate) then
                            call data%sdata%lhs%scale_diagonal(mat,elem_info,ifield,itime)
                        end if

                        ! Add time derivative to right-hand side
                        values = matmul(data%mesh%domain(idom)%elems(ielem)%mass,delta_q%get_field(elem_info,ifield,itime))/dt
                        call rhs%add_field(values,elem_info,ifield,itime)

                    end do !ifield
                end do !itime
            end do !ielem
        end do !idom

        ! Reassemble
        call data%sdata%lhs%assemble()
        call data%sdata%rhs%assemble()

        end associate


    end subroutine assemble
    !*****************************************************************************








    !>  Control algorithm for selectively updating the lhs matrix in the
    !!  nonlinear solver.
    !!
    !!  Reference:
    !!  Persson, P.-O., "High-Order Navier-Stokes Simulations using a Sparse 
    !!  Line-Based Discontinuous Galerkin Method", AIAA-2012-0456
    !!
    !!  @author Nathan A. Wukie
    !!  @date   6/22/2017
    !!
    !!  @param[in]  niter               Number of newton iterations
    !!  @param[in]  residual_ratio      R_{i}/R_{i-1}
    !!
    !----------------------------------------------------------------------------
    function update_lhs(self,A,niter,residual_ratio) result(update)
        class(DIRK_solver_controller_t),    intent(inout)   :: self
        type(chidg_matrix_t),               intent(in)      :: A
        integer(ik),                        intent(in)      :: niter
        real(rk),                           intent(in)      :: residual_ratio

        logical :: update

        ! Update lhs if:
        !   1: If matrix(lhs/A) hasn't been updated before
        !   2: number of newton iterations > 10
        !   3: residual norm increases by factor of 10 (divergence)
        !   4: being forced
        if ( all(A%stamp == NO_ID)      .or. &
            (niter > 6)                 .or. &
            (residual_ratio > 10._rk)   .or. &
            (self%force_update_lhs) ) then
            update = .true.
        else
            update = .false.
        end if

        ! Store action
        self%lhs_updated = update

        ! Turn off forced update
        !self%force_update_lhs = .true.
        self%force_update_lhs = .false.

    end function update_lhs
    !****************************************************************************
















end module type_DIRK
