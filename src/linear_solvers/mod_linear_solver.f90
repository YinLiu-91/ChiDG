module mod_linear_solver
#include <messenger.h>
    use mod_kinds,          only: rk, ik
    use type_linear_solver, only: linear_solver_t
    use type_dict,          only: dict_t


    ! IMPORT MATRIX SOLVERS
    use type_fgmres,                only: fgmres_t
    use type_fgmres_cgs,            only: fgmres_cgs_t
    use type_fgmres_cgs_correct,    only: fgmres_cgs_correct_t
    use type_fgmres_cgs_mg,         only: fgmres_cgs_mg_t
    use type_fgmres_cgs_mg_correct, only: fgmres_cgs_mg_correct_t
    

    



    type(fgmres_t)                  :: FGMRES
    type(fgmres_cgs_t)              :: FGMRES_CGS
    type(fgmres_cgs_correct_t)      :: FGMRES_CGS_CORRECT
    type(fgmres_cgs_mg_t)           :: FGMRES_CGS_MG
    type(fgmres_cgs_mg_correct_t)   :: FGMRES_CGS_MG_CORRECT






contains





    !>  Factory method for creating matrixsolver objects
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/17/2016
    !!
    !!  @param[in]      mstring     Character string used to select the appropriate matrixsolver for allocation
    !!  @param[inout]   msolver     matrixsolver_t that will be allocated to a concrete type.
    !!
    !---------------------------------------------------------------------------------------------------------------------
    subroutine create_linear_solver(lstring,lsolver,options)
        character(len=*),                    intent(in)      :: lstring
        class(linear_solver_t), allocatable, intent(inout)   :: lsolver
        type(dict_t), optional,              intent(inout)   :: options

        integer(ik) :: ierr


        select case (trim(lstring))
!            case ('direct','Direct')
!                allocate(msolver, source=DIRECT, stat=ierr)
!
!
!            case ('gaussseidel','GaussSeidel')
!                allocate(msolver, source=GAUSSSEIDEL, stat=ierr)
!
!            case ('sor','SOR')
!                allocate(msolver, source=SOR, stat=ierr)
!
!            case ('gmres','GMRES')
!                allocate(msolver, source=GMRES, stat=ierr)
!
            case ('fgmres','FGMRES')
                allocate(lsolver, source=FGMRES, stat=ierr)

            case ('fgmres_cgs', 'FGMRES_CGS')
                allocate(lsolver, source=FGMRES_CGS, stat=ierr)

            case ('fgmres_cgs_correct', 'FGMRES_CGS_CORRECT')
                allocate(lsolver, source=FGMRES_CGS_CORRECT, stat=ierr)

            case ('fgmres_cgs_mg', 'FGMRES_CGS_MG')
                allocate(lsolver, source=FGMRES_CGS_MG, stat=ierr)

            case ('fgmres_cgs_mg_correct', 'FGMRES_CGS_MG_CORRECT')
                allocate(lsolver, source=FGMRES_CGS_MG_CORRECT, stat=ierr)

            case default
                call chidg_signal(FATAL,"create_matrixsolver: matrix solver string did not match any valid type")

        end select
        if (ierr /= 0) call AllocationError




        !
        ! Call options initialization if present
        !
        if (present(options)) call lsolver%set(options)

        


        !
        ! Make sure the solver was allocated
        !
        if (.not. allocated(lsolver)) call chidg_signal(FATAL,"create_matrixsolver: solver was not allocated. Check that the desired solver was registered and instantiated in the mod_matrixsolver module")



    end subroutine create_linear_solver
    !*********************************************************************************************************************




end module mod_linear_solver
