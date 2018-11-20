module type_fgmres
#include <messenger.h>
    use mod_kinds,              only: rk, ik
    use mod_constants,          only: ZERO
    use mod_inv,                only: inv
    use mod_chidg_mpi,          only: ChiDG_COMM, GLOBAL_MASTER, IRANK, NRANK
    use mod_io,                 only: verbosity
    use mpi_f08

    use type_linear_solver,     only: linear_solver_t 
    use type_preconditioner,    only: preconditioner_t
    use type_solver_controller, only: solver_controller_t
    use type_chidg_data,        only: chidg_data_t
    use type_chidg_vector
    use type_chidg_matrix

    use operator_chidg_dot,     only: dot
    use operator_chidg_mv,      only: chidg_mv
    implicit none
        






    !> Generalized Minimum Residual linear system solver
    !!
    !!  @author Nathan A. Wukie
    !!  @date   5/11/2016
    !!
    !---------------------------------------------------------------------------------------------
    type, public, extends(linear_solver_t) :: fgmres_t

        integer(ik) :: m = 1000
        logical     :: force_reorthogonalize = .false.

    contains

        procedure   :: solve

    end type fgmres_t
    !*********************************************************************************************





contains


    !> Solution routine
    !!
    !!  @author Nathan A. Wukie
    !!  @date   5/11/2016
    !!
    !!  @author Nathan A. Wukie (AFRL) 
    !!  @date   6/23/2016
    !!  @note   parallelization
    !!
    !---------------------------------------------------------------------------------------------
    subroutine solve(self,A,x,b,M,solver_controller,data)
        class(fgmres_t),            intent(inout)               :: self
        type(chidg_matrix_t),       intent(inout)               :: A
        type(chidg_vector_t),       intent(inout)               :: x
        type(chidg_vector_t),       intent(inout)               :: b
        class(preconditioner_t),    intent(inout),  optional    :: M
        class(solver_controller_t), intent(inout),  optional    :: solver_controller
        type(chidg_data_t),         intent(in),     optional    :: data



        type(chidg_vector_t)                     :: r, r0, diff, xold, w, x0
        type(chidg_vector_t), allocatable        :: v(:), z(:)
        real(rk),            allocatable        :: h(:,:), h_square(:,:)
        real(rk),            allocatable        :: p(:), y(:), c(:), s(:), p_dim(:), y_dim(:)
        real(rk)                                :: pj, pjp, h_ij, h_ipj, htmp

        integer(ik) :: iparent, ierr, ivec, isol, nvecs, ielem
        integer(ik) :: i, j, k, l, ii                 ! Loop counters
        real(rk)    :: res, err, r0norm, gam, delta, norm_before, norm_after, crit

        logical     :: converged = .false.
        logical     :: max_iter  = .false.

        logical :: equal = .false.
        logical :: reorthogonalize = .false.

        integer(ik) :: idom_search, ielem_search, nelem_search, elems(6), iproc, idom, ientry


        !
        ! Start timer
        !
        call self%timer%reset()
        call self%timer%start()
        call write_line('           Linear Solver: ', io_proc=GLOBAL_MASTER, silence=(verbosity<4))

        

        !
        ! Update preconditioner
        !
        if (present(solver_controller)) then
            if (solver_controller%update_preconditioner(A)) call M%update(A,b)
        else
            call M%update(A,b)
        end if



        !
        ! Allocate and initialize Krylov vectors V
        !
        allocate(v(self%m+1),  &
                 z(self%m+1), stat=ierr)
        if (ierr /= 0) call AllocationError

        do ivec = 1,size(v)
            v(ivec) = b
            z(ivec) = b
            call v(ivec)%clear()
            call z(ivec)%clear()
        end do



        !
        ! Allocate hessenberg matrix to store orthogonalization
        !
        allocate(h(self%m + 1, self%m), stat=ierr)
        if (ierr /= 0) call AllocationError
        h = ZERO



        !
        ! Allocate vectors for solving hessenberg system
        !
        allocate(p(self%m+1), &
                 y(self%m+1), &
                 c(self%m+1), &
                 s(self%m+1), stat=ierr)
        if (ierr /= 0) call AllocationError
        p = ZERO
        y = ZERO
        c = ZERO
        s = ZERO



        !
        ! Set initial solution x. ZERO
        !
        x0 = x
        call x0%clear()
        call x%clear()


        self%niter = 0


        res = 1._rk
        do while (res > self%tol)

            !
            ! Clear working variables
            !
            do ivec = 1,size(v)
                call v(ivec)%clear()
                call z(ivec)%clear()
            end do


            p = ZERO
            y = ZERO
            c = ZERO
            s = ZERO
            h = ZERO



            !
            ! Compute initial residual r0, residual norm, and normalized r0
            !
            r0     = self%residual(A,x0,b)
            r0norm = r0%norm(ChiDG_COMM)
            v(1)   = r0/r0norm
            p(1)   = r0norm



            !
            ! Inner GMRES restart loop
            !
            nvecs = 0
            do j = 1,self%m
                nvecs = nvecs + 1
           
                
                !
                ! Apply preconditioner:  z(j) = Minv * v(j)
                !
                z(j) = M%apply(A,v(j))



                !
                ! Compute w = Av for the current iteration
                !
                w = chidg_mv(A,z(j))
                norm_before = w%norm(ChiDG_COMM)



                !
                ! Orthogonalization loop. Modified Gram-Schmidt (MGS)
                !
                do i = 1,j

                    h(i,j) = dot(w,v(i),ChiDG_COMM)
                    
                    w = w - h(i,j)*v(i)

                end do

                h(j+1,j) = w%norm(ChiDG_COMM)
                norm_after = h(j+1,j)



                !
                ! Reorthogonalize if necessary.
                !
                ! Reorthogonalization criteria based on:
                !
                ! Giraud and Langou 
                ! "A robust criterion for the modified Gram-Schmidt algorithm with selective reorthogonalization"
                ! SIAM J. of Sci. Comp.     Vol. 25, No. 2, pp. 417-441
                !
                ! They recommend L<1 for robustness, but it seems for these problems L can be increased.
                !
                L = 1.0_rk
                crit = sum(abs(h(1:j,j)))/norm_before
                
                if ( crit <  L ) reorthogonalize = .false.
                if ( crit >= L ) reorthogonalize = .true.
                

                if ( reorthogonalize .or. self%force_reorthogonalize ) then
                    call write_line('GMRES: Reorthogonalizing...', io_proc=GLOBAL_MASTER, silence=(verbosity<4))

                    do i = 1,j

                        htmp   = dot(w,v(i),ChiDG_COMM)
                        h(i,j) = h(i,j) + htmp

                        w = w - htmp*v(i)
                    end do

                    h(j+1,j) = w%norm(ChiDG_COMM)
                end if



                !
                ! Compute next Krylov vector
                !
                v(j+1) = w/h(j+1,j)



                !
                ! Previous Givens rotations on h
                !
                if (j /= 1) then
                    do i = 1,j-1
                        ! Need temp values here so we don't directly overwrite the h(i,j) and h(i+1,j) values 
                        h_ij     =  c(i)*h(i,j)  +  s(i)*h(i+1,j)
                        h_ipj    = -s(i)*h(i,j)  +  c(i)*h(i+1,j)


                        h(i,j)   = h_ij
                        h(i+1,j) = h_ipj
                    end do
                end if



                !
                ! Compute next rotation
                !
                !gam  = sqrt( h(j,j)*h(j,j)  +  h(j+1,j)*h(j+1,j) )
                gam  = hypot(h(j,j), h(j+1,j))
                c(j) = h(j,j)/gam
                s(j) = h(j+1,j)/gam


                !
                ! Givens rotation on h
                !
                h(j,j)   = gam
                h(j+1,j) = ZERO


                !
                ! Givens rotation on p. Need temp values here so we aren't directly overwriting the p(j) value until we want to
                !
                pj     =  c(j)*p(j)
                pjp    = -s(j)*p(j)

                p(j)   = pj
                p(j+1) = pjp


                
                !
                ! Update iteration counter
                !
                self%niter = self%niter + 1



                !
                ! Test exit conditions
                !
                res = abs(p(j+1))
                call write_line(res, io_proc=GLOBAL_MASTER, silence=(verbosity<4))
                converged = (res < self%tol)
                
                if ( converged ) then
                    exit
                end if

            end do  ! Outer GMRES Loop - restarts after m iterations





            !
            ! Solve upper-triangular system y = hinv * p
            !
            if (allocated(h_square)) then
                deallocate(h_square,p_dim,y_dim)
            end if
            
            allocate(h_square(nvecs,nvecs), &
                     p_dim(nvecs),          &
                     y_dim(nvecs), stat=ierr)
            if (ierr /= 0) call AllocationError




            !
            ! Store h and p values to appropriately sized matrices
            !
            do l=1,nvecs
                do k=1,nvecs
                    h_square(k,l) = h(k,l)
                end do
                p_dim(l) = p(l)
            end do



            !
            ! Solve the system
            !
            h_square = inv(h_square)
            y_dim = matmul(h_square,p_dim)



            !
            ! Reconstruct solution
            !
            x = x0
            do isol = 1,nvecs
                x = x + y_dim(isol)*z(isol)
            end do



            !
            ! Test exit condition
            !
            if ( converged ) then
                exit
            else
                x0 = x
            end if



        end do   ! while




        call MPI_Barrier(ChiDG_COMM,ierr)


        !
        ! Report
        !
        err = self%error(A,x,b)
        call self%timer%stop()
        !call self%timer%report('Linear solver compute time: ')
        call write_line('   Linear Solver error: ',        err,                  delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<5))
        call write_line('   Linear Solver compute time: ', self%timer%elapsed(), delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<5))
        call write_line('   Linear Solver iterations: ',   self%niter,           delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<5))


    end subroutine solve
    !************************************************************************************************************



end module type_fgmres
