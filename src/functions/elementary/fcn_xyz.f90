module fcn_xyz
    use mod_kinds,      only: rk,ik
    use type_function,  only: function_t
    use type_point,     only: point_t
    use type_point_ad,  only: point_ad_t
    use DNAD_D
    implicit none
    private





    !> xyz function
    !!
    !!  \f$     f(t,\vec{x}) = xyz      \f$
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !---------------------------------------------------------------------------------
    type, extends(function_t), public :: xyz_f

    contains

        procedure   :: init
        procedure   :: compute

    end type xyz_f
    !**********************************************************************************



contains



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/2/2016
    !!
    !-------------------------------------------------------------------------
    subroutine init(self)
        class(xyz_f),  intent(inout)    :: self

        !
        ! Set function name
        !
        call self%set_name("xyz")


        !
        ! Set function options to default settings
        !


    end subroutine init
    !*************************************************************************









    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/2/2016
    !!
    !!
    !---------------------------------------------------------------------------------
    impure elemental function compute(self,time,coord) result(val)
        class(xyz_f),       intent(inout)   :: self
        real(rk),           intent(in)      :: time
        type(point_ad_t),   intent(in)      :: coord

        type(AD_D)                  :: val

        ! f(x) = x * y * z
        val = coord%c1_ * coord%c2_ * coord%c3_

    end function compute
    !**********************************************************************************



end module fcn_xyz
