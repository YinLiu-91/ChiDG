module type_prescribed_mesh_motion
#include <messenger.h>
    use mod_constants
    use mod_kinds,                              only: rk, ik
    use type_mesh_motion,                       only: mesh_motion_t
    use mod_prescribed_mesh_motion_function,    only: create_prescribed_mesh_motion_function
    use type_prescribed_mesh_motion_function,   only: prescribed_mesh_motion_function_t
    use type_chidg_worker,                      only: chidg_worker_t
    use type_mesh,                              only: mesh_t 
    implicit none


    !>  Mesh motion class. Abstract interface to enable treatment of prescribed mesh motion.
    !!
    !!  Data flow:
    !!  gridfile :-- readprescribedmeshmotion_hdf --> pmm_group, pmm_domain_data ...
    !!  :-- init_pmm_group, init_pmm_domain --> pmm(:), mesh
    !!
    !!  @author Eric Wolf
    !!  @date   3/16/2017
    !!
    !---------------------------------------------------------------------------------------------------------------


    type, public, extends(mesh_motion_t)     :: prescribed_mesh_motion_t
        
        ! pmmf_name is the name of the prescribed_mesh_motion_function_t associated with this pmm
        character(:), allocatable                                   :: pmmf_name

        ! pmm_function is the prescribed_mesh_motion_function_t associated with this pmm
        ! This is what really specifies the grid positions and velocities.
        class(prescribed_mesh_motion_function_t), allocatable                     :: pmmf

    contains
        procedure :: init_name
        procedure :: init
        procedure :: update
        procedure :: apply
        
        !Set the name 
        procedure       :: set_pmmf_name
        ! Instantiate the pmmf and assign it to the pmm
        procedure       :: add_pmmf


        !These procedures compute the values of the grid positions and velocities
        ! from the pmmf associated with the pmm,
        ! then call element and face procedures to compute grid Jacobians.
!        procedure    :: update_element => pmm_update_element 
!        procedure    :: update_face => pmm_update_face
               

    end type prescribed_mesh_motion_t
    
contains

    subroutine init_name(self)
        class(prescribed_mesh_motion_t), intent(inout) :: self

        call self%set_family_name('PMM')

    end subroutine init_name

    
    subroutine init(self, mesh)
        class(prescribed_mesh_motion_t), intent(inout) :: self
        type(mesh_t),              intent(inout) :: mesh 

        call self%init_name()

    end subroutine init

    subroutine update(self, mesh, time)
        class(prescribed_mesh_motion_t), intent(inout) :: self
        type(mesh_t),              intent(inout) :: mesh 
        real(rk),                       intent(in)  :: time

        ! Do nothing!

    end subroutine update 

    subroutine apply(self, mesh, time)
        class(prescribed_mesh_motion_t), intent(inout) :: self
        type(mesh_t),              intent(inout) :: mesh 
        real(rk),                       intent(in)  :: time

        integer(ik) :: idom, mm_ID, inode

        do idom = 1,mesh%ndomains()
            mm_ID = mesh%domain(idom)%mm_ID
            if (mm_ID == self%mm_ID) then

                do inode = 1, size(mesh%domain(idom)%nodes,1)
                    mesh%domain(idom)%dnodes(inode,:) = self%pmmf%compute_pos(time,mesh%domain(idom)%nodes(inode,:)) - &
                        mesh%domain(idom)%nodes(inode,:)
                    mesh%domain(idom)%vnodes(inode,:) = self%pmmf%compute_vel(time, mesh%domain(idom)%nodes(inode,:))
                end do
            end if
        end do


    end subroutine apply 



    !>
    !!  This subroutine takes a an input pmm (from a pmm_group, which is generated by reading in the
    !!  grid file and initializing a pmm instance according to a PMM group),
    !!  and uses this pmm instance as an allocation source for the present pmm.
    !!
    !!  @author Eric Wolf
    !!  @date 4/7/2017
    !--------------------------------------------------------------------------------
    subroutine init_mm_group(self,pmm_in)
        class(prescribed_mesh_motion_t),               intent(inout)       :: self
        class(prescribed_mesh_motion_t),               intent(inout)       :: pmm_in


        integer(ik)     :: ierr
        

        call self%set_name(pmm_in%get_name())
        self%pmmf_name = pmm_in%pmmf_name
        if (allocated(self%pmmf)) deallocate(self%pmmf)
        allocate(self%pmmf, source = pmm_in%pmmf, stat=ierr)
        if (ierr /= 0) call AllocationError

    end subroutine init_mm_group
    !********************************************************************************

    
        
    !>
    !!
    !!
    !!  @author Eric Wolf
    !!  @date 4/7/2017
    !--------------------------------------------------------------------------------
    subroutine set_pmmf_name(self, pmmfstring)
        class(prescribed_mesh_motion_t),        intent(inout)   :: self
        character(*),                           intent(in)      :: pmmfstring

        self%pmmf_name = pmmfstring

    end subroutine
    !********************************************************************************


    !>
    !!  Called from get_pmm_hdf
    !! 
    !!  @author Eric Wolf
    !!  @date 4/7/2017
    !--------------------------------------------------------------------------------
    subroutine add_pmmf(self, pmmfstring)
        class(prescribed_mesh_motion_t),        intent(inout)   :: self
        character(*),                           intent(in)      :: pmmfstring
        class(prescribed_mesh_motion_function_t), allocatable                :: pmmf
            
        integer(ik)     :: ierr
        call self%set_pmmf_name(pmmfstring)
        call create_prescribed_mesh_motion_function(pmmf, pmmfstring)
        if (allocated(self%pmmf)) deallocate(self%pmmf)
        allocate(self%pmmf, source = pmmf, stat=ierr)
        if (ierr /= 0) call AllocationError

    end subroutine
    !********************************************************************************






end module type_prescribed_mesh_motion
