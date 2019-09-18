module eqn_filtered_euler_FP0
#include <messenger.h>
    use type_equation_set,          only: equation_set_t
    use type_equation_builder,      only: equation_builder_t
    use type_solverdata,            only: solverdata_t
    use type_fluid_pseudo_timestep, only: fluid_pseudo_timestep_t
    implicit none


    !>
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------------
    type, public, extends(equation_builder_t) :: filtered_euler_FP0

    contains

        procedure   :: init
        procedure   :: build

    end type filtered_euler_FP0
    !********************************************************************************************




contains


    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/30/2016
    !!
    !---------------------------------------------------------------------------------------------
    subroutine init(self)
        class(filtered_euler_FP0),   intent(inout)  :: self

        call self%set_name('Filtered Euler FP0')

    end subroutine init
    !*********************************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/30/2016
    !!
    !!
    !---------------------------------------------------------------------------------------------
    function build(self,blueprint) result(euler_eqns)
        class(filtered_euler_FP0),  intent(in)  :: self
        character(*),           intent(in)  :: blueprint

        type(equation_set_t)            :: euler_eqns
        type(fluid_pseudo_timestep_t)   :: fluid_pseudo_time

        !
        ! Set equation set name
        !
        call euler_eqns%set_name('Filtered Euler FP0')
        

        !
        ! Add spatial operators
        !
        select case (trim(blueprint))


            case('default')

                call euler_eqns%add_operator('Euler Volume Flux')
                call euler_eqns%add_operator('Euler Boundary Average Flux')
                call euler_eqns%add_operator('Euler Roe Flux')
                call euler_eqns%add_operator('Euler BC Flux')
                call euler_eqns%add_operator('Euler Volume Cylindrical Source')

                call euler_eqns%add_model('Ideal Gas')
                call euler_eqns%add_pseudo_timestep(fluid_pseudo_time)

            case default
                call chidg_signal_one(FATAL, "build_euler: I didn't recognize the construction parameter &
                                              that was passed to build the equation set.", blueprint)

        end select


    end function build
    !**********************************************************************************************

















end module eqn_filtered_euler_FP0
