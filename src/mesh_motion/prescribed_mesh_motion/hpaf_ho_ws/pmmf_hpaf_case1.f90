module pmmf_hpaf_case1
#include <messenger.h>
    use mod_kinds,      only: rk,ik
    use mod_constants,  only: ZERO, HALF, ONE, TWO, THREE, FIVE, EIGHT, PI
    use type_prescribed_mesh_motion_function,  only: prescribed_mesh_motion_function_t
    implicit none
    private








    !>  hpaf_case1 mesh motion. 
    !!
    !!  @author Eric Wolf
    !!  @date   3/15/2017 
    !!
    !!
    !-------------------------------------------------------------------------------
    type, extends(prescribed_mesh_motion_function_t), public :: hpaf_case1_pmmf
        private

        
    contains

        procedure   :: init
        procedure   :: compute_pos
        procedure   :: compute_vel

    end type hpaf_case1_pmmf
    !********************************************************************************



contains




    !>
    !!
    !!  @author Eric Wolf
    !!  @date   3/15/2017 
    !!
    !-------------------------------------------------------------------------
    subroutine init(self)
        class(hpaf_case1_pmmf),  intent(inout)  :: self

        !
        ! Set function name
        !
        call self%set_name("hpaf_case1")


        !
        ! Set function options to default settings
        !
        !call self%add_option('option_name',option_val_rk)
    
    end subroutine init
    !*************************************************************************



    !>
    !!
    !!  @author Eric Wolf
    !!  @date   3/15/2017 
    !!
    !!
    !-----------------------------------------------------------------------------------------
    function compute_pos(self,time,node) result(val)
        class(hpaf_case1_pmmf),     intent(inout)   :: self
        real(rk),                   intent(in)      :: time
        real(rk),                   intent(in)      :: node(3)

        integer(ik) :: ivar
        real(rk)    :: val(3)

        real(rk)    :: b1, b2, b3, &
                       A2, A3, x0, y0, x_ale, y_ale, &
                       xc, yc, height, theta

        b1 = time**TWO*(time**TWO-4._rk*time+4._rk)
        b2 = time**TWO*(3._rk-time)/4._rk
        b3 = time**THREE*(-8._rk*time**THREE+51._rk*time**TWO-111._rk*time+84._rk)/16._rk

        !Case 1
        if (time <= TWO) height = b2
        if (time >  TWO) height = ONE
        theta = ZERO

!        !Case 2
!        height = b2
!        A2 = (60._rk*PI/180._rk)
!        theta = A2*b1
!        
!        !Case 3 
!        height = b3
!        A3 = (80._rk*PI/180._rk)
!        theta = A3*b1

        !Center of motion nodeinates
        xc = 1._rk/3._rk
        yc = 0._rk

        !Get the reference frame nodeinates of the grid point
        x0 = node(1)
        y0 = node(2)

        !Rotate about the center of motion
        x_ale =  cos(theta)*(x0-xc)+sin(theta)*(y0-yc) + xc
        y_ale = -sin(theta)*(x0-xc)+cos(theta)*(y0-yc) + yc

        !Translate vertically
        y_ale = y_ale + height



        val(1) = x_ale
        val(2) = y_ale
        val(3) = node(3)
        
    end function compute_pos
    !**********************************************************************************






    !>
    !!
    !!  @author Eric Wolf
    !!  @date   3/15/2017 
    !!
    !!
    !-----------------------------------------------------------------------------------------
    function compute_vel(self,time,node) result(val)
        class(hpaf_case1_pmmf),     intent(inout)  :: self
        real(rk),                       intent(in)  :: time
        real(rk),                  intent(in)  :: node(3)

        integer(ik)                                 :: ivar
        real(rk)                                   :: val(3)
        real(rk)                                    :: b1, b2, b3, db1dt, db2dt, db3dt, &
                                                        A2, A3, x0, y0, x_ale, y_ale, &
                                                        xc, yc, height, theta, dheightdt, dthetadt


        b1 = time**TWO*(time**TWO-4._rk*time+4._rk)
        b2 = time**TWO*(3._rk-time)/4._rk
        b3 = time**THREE*(-8._rk*time**THREE+51._rk*time**TWO-111._rk*time+84._rk)/16._rk

        db1dt = TWO*time*(time**TWO-4._rk*time+4._rk) + &
                time**TWO*(TWO*time-4._rk)
        db2dt = TWO*time*(3._rk-time)/4._rk + &
                time**TWO*(-1._rk)/4._rk
        db3dt = THREE*time**TWO*(-8._rk*time**THREE+51._rk*time**TWO-111._rk*time+84._rk)/16._rk + &
                time**THREE*(-24._rk*time**TWO+102._rk*time-111._rk)/16._rk


        !Case 1
        height = b2
        theta = ZERO
        dheightdt = db2dt
        dthetadt = ZERO

!        !Case 2
!        height = b2
!        A2 = (60._rk*PI/180._rk)
!        theta = A2*b1
!        dheightdt = db2dt
!        dthetadt = A2*db1dt
!
!        !Case 3 
!        height = b3
!        A3 = (80._rk*PI/180._rk)
!        theta = A3*b1
!        dheightdt = db3dt
!        dthetadt = A3*db1dt

        !Center of motion nodeinates
        xc = 1._rk/3._rk
        yc = 0._rk

        !Get the reference frame nodeinates of the grid point
        x0 = node(1)
        y0 = node(2)

        !Rotate about the center of motion
        x_ale = -sin(theta)*dthetadt*(x0-xc)+cos(theta)*dthetadt*(y0-yc) 
        y_ale = -cos(theta)*dthetadt*(x0-xc)-sin(theta)*dthetadt*(y0-yc)

        !Translate vertically
        y_ale = y_ale + dheightdt


        if (time > TWO) x_ale = ZERO
        if (time > TWO) y_ale = ZERO


        val(1) = x_ale
        val(2) = y_ale
        val(3) = ZERO 
 
        
    end function compute_vel
    !**********************************************************************************


end module pmmf_hpaf_case1
