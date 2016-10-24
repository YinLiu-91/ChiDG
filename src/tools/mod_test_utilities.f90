module mod_test_utilities
#include <messenger.h>
    use mod_kinds,                  only: rk,ik
    use mod_constants,              only: ZERO, ONE, TWO, THREE, FOUR, FIVE, SIX
    use mod_chidg_mpi,              only: IRANK
    use mod_plot3d_utilities,       only: get_block_points_plot3d,   &
                                          get_block_elements_plot3d, &
                                          get_block_boundary_faces_plot3d
    use mod_hdf_utilities,          only: initialize_file_hdf, add_domain_hdf, &
                                          open_domain_hdf, close_domain_hdf,   &
                                          set_bc_patch_hdf, add_bc_state_hdf,  &
                                          set_contains_grid_hdf, close_file_hdf, close_hdf
    use mod_bc,                     only: create_bc
    use mod_gridgen_blocks,         only: create_mesh_file__singleblock,                    &
                                          create_mesh_file__multiblock,                     &
                                          create_mesh_file__D2E8M1,                         &
                                          meshgen_1x1x1_linear, meshgen_1x1x1_unit_linear,  &
                                          meshgen_2x2x2_linear, meshgen_2x2x1_linear,       &
                                          meshgen_3x3x3_linear, meshgen_3x3x3_unit_linear,  &
                                          meshgen_3x3x1_linear, meshgen_4x1x1_linear,       &
                                          meshgen_2x1x1_linear, meshgen_3x1x1_linear,       &
                                          meshgen_40x15x1_linear, meshgen_15x15x1_linear,   &
                                          meshgen_15x15x2_linear, meshgen_15x15x3_linear
    use mod_gridgen_cylinder,       only: create_mesh_file__cylinder
    use mod_gridgen_smoothbump,     only: create_mesh_file__smoothbump

    use type_point,                 only: point_t
    use type_bc_state_wrapper,      only: bc_state_wrapper_t
    use type_domain_connectivity,   only: domain_connectivity_t
    use hdf5
    implicit none


contains



    !>  Create an actual ChiDG-formatted grid file that could be
    !!  read in by a test. Also with initialized boundary conditions.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   10/17/2016
    !!
    !!
    !---------------------------------------------------------------------------
    subroutine create_mesh_file(selector, filename, equation_set1, equation_set2, &
                                                    bc_states1, bc_states2,       &
                                                    nelem_xi,nelem_eta,nelem_zeta,clusterx)
        character(*),                           intent(in)  :: selector
        character(*),                           intent(in)  :: filename
        character(*),               optional,   intent(in)  :: equation_set1
        character(*),               optional,   intent(in)  :: equation_set2
        type(bc_state_wrapper_t),   optional,   intent(in)  :: bc_states1(:)
        type(bc_state_wrapper_t),   optional,   intent(in)  :: bc_states2(:)
        integer(ik),                optional,   intent(in)  :: nelem_xi
        integer(ik),                optional,   intent(in)  :: nelem_eta
        integer(ik),                optional,   intent(in)  :: nelem_zeta
        integer(ik),                optional,   intent(in)  :: clusterx


        character(:),   allocatable :: user_msg
        integer(ik)                 :: ierr


        ! Generate grid file base on selector case.
        select case (trim(selector))
            !
            ! Simple, linear, block grids
            !
            case("D1 E1 M1", "D1 E4 M1", "D1 E16 M1", "D1 E27 M1", "D1 NxNxN")
                call create_mesh_file__singleblock(filename,trim(selector),equation_set1,bc_states1,nelem_xi,nelem_eta,nelem_zeta,clusterx)

            case("D2 E1 M1")
                call create_mesh_file__multiblock(filename,"D1 E1 M1","D1 E1 M1",equation_set1,equation_set2,bc_states1,bc_states2)
            case("D2 E2 M1")
                call create_mesh_file__multiblock(filename,"D1 E2 M1","D1 E2 M1",equation_set1,equation_set2,bc_states1,bc_states2)
            case("D2 E27 M1")
                call create_mesh_file__multiblock(filename,"D1 E27 M1","D1 E27 M1",equation_set1,equation_set2,bc_states1,bc_states2)

            case("D2 E8 M1 : Abutting : Matching")
                call create_mesh_file__D2E8M1(filename,abutting=.true.,             &
                                                       matching=.true.,             &
                                                       equation_set1=equation_set1, &
                                                       equation_set2=equation_set2, &
                                                       bc_states1=bc_states1,       &
                                                       bc_states2=bc_states2)
            case("D2 E8 M1 : Overlapping : Matching")
                call create_mesh_file__D2E8M1(filename,abutting=.false.,matching=.true.,    &
                                                       equation_set1=equation_set1,         &
                                                       equation_set2=equation_set2,         &
                                                       bc_states1=bc_states1,               &
                                                       bc_states2=bc_states2)
            case("D2 E8 M1 : Overlapping : NonMatching")
                call create_mesh_file__D2E8M1(filename,abutting=.false.,matching=.false.,   &
                                                       equation_set1=equation_set1,         &
                                                       equation_set2=equation_set2,         &
                                                       bc_states1=bc_states1,               &
                                                       bc_states2=bc_states2)

            !
            ! Circular cylinder
            !
            case("Cylinder : Diagonal : Matching")
                call create_mesh_file__cylinder(filename,overlap_deg=0._rk)
            case("Cylinder : Diagonal : NonMatching SingleDonor")
                call create_mesh_file__cylinder(filename,overlap_deg=2.5_rk)
            case("Cylinder : Diagonal : NonMatching MultipleDonor")
                call create_mesh_file__cylinder(filename,overlap_deg=5.0_rk)


            !
            ! Smooth Bump
            !
            case("Smooth Bump")
                call create_mesh_file__smoothbump(filename,nelem_xi  =nelem_xi,         &
                                                           nelem_eta =nelem_eta,        &
                                                           nelem_zeta=nelem_zeta,       &
                                                           equation_set1=equation_set1, &
                                                           bc_states1=bc_states1)

            case default
                user_msg = "create_mesh_file: There was no valid case that matched the incoming string"
                call chidg_signal(FATAL,user_msg)

        end select


    end subroutine create_mesh_file
    !***************************************************************************







    !>  Generate a set of points for a mesh. String input calls specialized
    !!  procedure for generating the points
    !!
    !!  @author Nathan A. Wukie
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   5/24/2016
    !!
    !!  @param[in]      string          Character string used to select a specialized 
    !!                                  meshgen call
    !!  @param[inout]   nodes           Array of node coordinates for the grid
    !!  @param[inout]   connectivity    Connectivity data for the grid
    !--------------------------------------------------------------------
    subroutine create_mesh(string,nodes,connectivity)
        character(*),                   intent(in)      :: string
        type(point_t),  allocatable,    intent(inout)   :: nodes(:)
        type(domain_connectivity_t),    intent(inout)   :: connectivity

        integer(ik)                                     :: idomain, mapping, ielem
        integer(ik),    allocatable                     :: elements(:,:)
        real(rk),       allocatable, dimension(:,:,:)   :: xcoords,ycoords,zcoords

        select case (trim(string))
            case ('1x1x1','111')
                call meshgen_1x1x1_linear(xcoords,ycoords,zcoords)

            case ('1x1x1_unit','111u')
                call meshgen_1x1x1_unit_linear(xcoords,ycoords,zcoords)

            case ('3x3x3','333')
                call meshgen_3x3x3_linear(xcoords,ycoords,zcoords)

            case ('3x3x3_unit','333u')
                call meshgen_3x3x3_unit_linear(xcoords,ycoords,zcoords)

            case ('2x2x2','222')
                call meshgen_2x2x2_linear(xcoords,ycoords,zcoords)

            case ('2x2x1','221')
                call meshgen_2x2x1_linear(xcoords,ycoords,zcoords)

            case ('3x3x1','331')
                call meshgen_3x3x1_linear(xcoords,ycoords,zcoords)

            case ('4x1x1','411')
                call meshgen_4x1x1_linear(xcoords,ycoords,zcoords)

            case ('3x1x1','311')
                call meshgen_3x1x1_linear(xcoords,ycoords,zcoords)

            case ('2x1x1','211')
                call meshgen_2x1x1_linear(xcoords,ycoords,zcoords)

            case ('40x15x1')
                call meshgen_40x15x1_linear(xcoords,ycoords,zcoords)

            case ('15x15x1')
                call meshgen_15x15x1_linear(xcoords,ycoords,zcoords)

            case ('15x15x2')
                call meshgen_15x15x2_linear(xcoords,ycoords,zcoords)

            case ('15x15x3')
                call meshgen_15x15x3_linear(xcoords,ycoords,zcoords)


            case default
                call chidg_signal(FATAL,'String identifying mesh generation routine was not recognized')
        end select


        !
        ! Generate nodes, connectivity
        !
        mapping = 1
        idomain = 1
        nodes    = get_block_points_plot3d(xcoords,ycoords,zcoords)
        elements = get_block_elements_plot3d(xcoords,ycoords,zcoords,mapping,idomain)

        call connectivity%init(size(elements,1),size(nodes))
        do ielem = 1,size(elements,1)
            call connectivity%data(ielem)%init(1)
            call connectivity%data(ielem)%set_element_partition(IRANK)
            connectivity%data(ielem)%data = elements(ielem,:)
        end do

    end subroutine create_mesh
    !****************************************************************************



















end module mod_test_utilities
