module mod_test_utilities
#include <messenger.h>
    use mod_kinds,                  only: rk,ik
    use mod_constants,              only: ZERO, ONE, TWO, THREE, FOUR, FIVE, SIX
    use mod_string,                 only: string_t
    use mod_chidg_mpi,              only: IRANK
    use mod_plot3d_utilities,       only: get_block_points_plot3d,   &
                                          get_block_elements_plot3d, &
                                          get_block_boundary_faces_plot3d
    use mod_bc,                     only: create_bc
    use mod_gridgen_blocks_pmm,     only: create_mesh_file__pmm__singleblock,               &
                                          create_mesh_file__pmm__sinusoidal__singleblock
    use mod_gridgen_blocks,         only: create_mesh_file__singleblock,                    &
                                          create_mesh_file__singleblock_M2,                 &
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

    use mod_gridgen_uniform_flow_pmm,               only: create_mesh_file__uniform_flow_pmm
    use mod_gridgen_convecting_vortex_pmm,               only: create_mesh_file__convecting_vortex_pmm
    use mod_gridgen_scalar_advection_pmm,           only: create_mesh_file__scalar_advection_pmm, &
                                                            create_mesh_file__scalar_advection_translation_pmm
    use mod_gridgen_scalar_advection_diffusion_pmm, only: create_mesh_file__scalar_advection_diffusion_pmm, &
                                                            create_mesh_file__scalar_advection_diffusion_pmm__multiblock
    use type_point,                 only: point_t
    use type_bc_state_group,        only: bc_state_group_t
    use type_functional_group,      only: functional_group_t
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
    !!  @param[in]  selector        String, specifying the mesh creation routine to call.
    !!  @param[in]  filename        String, filename that gets written to.
    !!  @param[in]  equation_sets   Strings, indicating the equation set to be initialized on each domain.
    !!  @param[in]  group_names     Strings, indicating for each face of each domain, 
    !!                              what bc_state_group it is associated with.
    !!  @param[in]  bc_state_groups Array of bc_state_groups, each defining a set of bc_states. These
    !!                              each have a name. The entries in group_names selects one of these sets
    !!                              for a domain patch.
    !!
    !------------------------------------------------------------------------------------------
    subroutine create_mesh_file(selector, filename, equation_sets,                     &
                                                    group_names,                       &
                                                    bc_state_groups,                   &
                                                    functionals,                       &
                                                    nelem_xi,  nelem_eta,  nelem_zeta, &
                                                    clusterx, save_intermediate_files, &
                                                    x_max_in, x_min_in, y_max_in, y_min_in, z_max_in, z_min_in)
        character(*),                           intent(in)      :: selector
        character(*),                           intent(in)      :: filename
        type(string_t),             optional,   intent(in)      :: equation_sets(:)
        type(string_t),             optional,   intent(in)      :: group_names(:,:)
        type(bc_state_group_t),     optional,   intent(in)      :: bc_state_groups(:)
        type(functional_group_t),   optional,   intent(inout)   :: functionals
        integer(ik),                optional,   intent(in)      :: nelem_xi
        integer(ik),                optional,   intent(in)      :: nelem_eta
        integer(ik),                optional,   intent(in)      :: nelem_zeta
        integer(ik),                optional,   intent(in)      :: clusterx
        real(rk),                   optional,   intent(in)      :: x_max_in
        real(rk),                   optional,   intent(in)      :: x_min_in
        real(rk),                   optional,   intent(in)      :: y_max_in
        real(rk),                   optional,   intent(in)      :: y_min_in
        real(rk),                   optional,   intent(in)      :: z_max_in
        real(rk),                   optional,   intent(in)      :: z_min_in
        logical,                    optional,   intent(in)      :: save_intermediate_files

        character(:),   allocatable :: user_msg
        integer(ik)                 :: ierr


        !
        ! Generate grid file base on selector case.
        !
        select case (trim(selector))

            !
            ! Simple, linear, block grids
            !
            case("D1 NxNxN")
                call create_mesh_file__singleblock(filename, equation_sets,                     &
                                                             group_names,                       &
                                                             bc_state_groups,                   &
                                                             nelem_xi, nelem_eta, nelem_zeta,   &
                                                             clusterx, x_max_in, x_min_in, y_max_in, y_min_in, z_max_in, z_min_in,functional=functionals)

            case("D2 NxNxN M1")
                call create_mesh_file__multiblock(filename, equation_sets,                      &
                                                            group_names,                        &
                                                            bc_state_groups,                    &
                                                            nelem_xi,  nelem_eta,  nelem_zeta,  &
                                                            clusterx=clusterx,functional=functionals)

            case("D2 E8 M1 : Abutting : Matching")
                call create_mesh_file__D2E8M1(filename,abutting       = .true.,        &
                                                       matching       = .true.,        &
                                                       equation_sets  = equation_sets, &
                                                       group_names    = group_names,   &
                                                       bc_state_groups = bc_state_groups)
            case("D2 E8 M1 : Overlapping : Matching")
                call create_mesh_file__D2E8M1(filename,abutting       = .false.,       &
                                                       matching       = .true.,        &
                                                       equation_sets  = equation_sets, &
                                                       group_names    = group_names,   &
                                                       bc_state_groups = bc_state_groups)
            case("D2 E8 M1 : Overlapping : NonMatching")
                call create_mesh_file__D2E8M1(filename,abutting        = .false.,       &
                                                       matching        = .false.,       &
                                                       equation_sets   = equation_sets, &
                                                       group_names     = group_names,   &
                                                       bc_state_groups = bc_state_groups)



            !
            ! Simple, quadratic, block grids
            !
            case("D1 NxNxN M2")
                call create_mesh_file__singleblock_M2(filename, equation_sets,                     &
                                                                group_names,                       &
                                                                bc_state_groups,                   &
                                                                nelem_xi, nelem_eta, nelem_zeta,   &
                                                                clusterx, x_max_in, x_min_in,      &
                                                                functional = functionals)



            !
            ! Circular cylinder
            !
            case("Cylinder : Diagonal : Matching")
                call create_mesh_file__cylinder(filename,overlap_deg     = 0._rk,         &
                                                         group_names     = group_names,   &
                                                         bc_state_groups = bc_state_groups)
            case("Cylinder : Diagonal : NonMatching SingleDonor")
                call create_mesh_file__cylinder(filename,overlap_deg     = 2.5_rk,        &
                                                         group_names     = group_names,   &
                                                         bc_state_groups = bc_state_groups)
            case("Cylinder : Diagonal : NonMatching MultipleDonor")
                call create_mesh_file__cylinder(filename,overlap_deg     = 5.0_rk,        &
                                                         group_names     = group_names,   &
                                                         bc_state_groups = bc_state_groups)


            !
            ! Smooth Bump
            !
            case("Smooth Bump")
                call create_mesh_file__smoothbump(filename,nelem_xi        = nelem_xi,        &
                                                           nelem_eta       = nelem_eta,       &
                                                           nelem_zeta      = nelem_zeta,      &
                                                           equation_sets   = equation_sets,   &
                                                           group_names     = group_names,     &
                                                           bc_state_groups = bc_state_groups, &
                                                           save_intermediate_files = save_intermediate_files)

            !
            ! PMM
            !
            case("D1 NxNxN PMM")
                call create_mesh_file__pmm__singleblock(filename, equation_sets,                &
                                                             group_names,                       &
                                                             bc_state_groups,                   &
                                                             nelem_xi, nelem_eta, nelem_zeta,   &
                                                             clusterx)
            case("D1 NxNxN PMM_SIN")
                call create_mesh_file__pmm__sinusoidal__singleblock(filename, equation_sets,    &
                                                             group_names,                       &
                                                             bc_state_groups,                   &
                                                             nelem_xi, nelem_eta, nelem_zeta,   &
                                                             clusterx)


            !
            ! Uniform Flow PMM (regression test) 
            !
            case("Uniform Flow PMM")
                call create_mesh_file__uniform_flow_pmm(filename,nelem_xi  = nelem_xi,          &
                                                           nelem_eta       = nelem_eta,         &
                                                           nelem_zeta      = nelem_zeta,        &
                                                           equation_sets   = equation_sets,     &
                                                           group_names     = group_names,       &
                                                           bc_state_groups = bc_state_groups)
            case("Convecting Vortex PMM")
                call create_mesh_file__convecting_vortex_pmm(filename,nelem_xi = nelem_xi,      &
                                                           nelem_eta       = nelem_eta,         &
                                                           nelem_zeta      = nelem_zeta,        &
                                                           equation_sets   = equation_sets,     &
                                                           group_names     = group_names,       &
                                                           bc_state_groups = bc_state_groups)


             case("Scalar Advection PMM")
                call create_mesh_file__scalar_advection_pmm(filename,nelem_xi        = nelem_xi,        &
                                                           nelem_eta       = nelem_eta,       &
                                                           nelem_zeta      = nelem_zeta,      &
                                                           equation_sets   = equation_sets,   &
                                                           group_names     = group_names,     &
                                                           bc_state_groups = bc_state_groups)

             case("Scalar Advection Translation PMM")
                call create_mesh_file__scalar_advection_translation_pmm(filename,nelem_xi        = nelem_xi,        &
                                                           nelem_eta       = nelem_eta,       &
                                                           nelem_zeta      = nelem_zeta,      &
                                                           equation_sets   = equation_sets,   &
                                                           group_names     = group_names,     &
                                                           bc_state_groups = bc_state_groups)

             case("Scalar Advection Diffusion PMM")
                call create_mesh_file__scalar_advection_diffusion_pmm(filename,nelem_xi        = nelem_xi,        &
                                                           nelem_eta       = nelem_eta,       &
                                                           nelem_zeta      = nelem_zeta,      &
                                                           equation_sets   = equation_sets,   &
                                                           group_names     = group_names,     &
                                                           bc_state_groups = bc_state_groups)

             case("Scalar Advection Diffusion PMM Multiblock")
                call create_mesh_file__scalar_advection_diffusion_pmm__multiblock(filename,nelem_xi        = nelem_xi,        &
                                                           nelem_eta       = nelem_eta,       &
                                                           nelem_zeta      = nelem_zeta,      &
                                                           equation_sets   = equation_sets,   &
                                                           group_names     = group_names,     &
                                                           bc_state_groups = bc_state_groups)



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
        real(rk),       allocatable,    intent(inout)   :: nodes(:,:)
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

        call connectivity%init(trim(string),size(elements,1),size(nodes))
        do ielem = 1,size(elements,1)
            call connectivity%data(ielem)%init(1)
            call connectivity%data(ielem)%set_element_partition(IRANK)
            connectivity%data(ielem)%data = elements(ielem,:)
        end do

    end subroutine create_mesh
    !****************************************************************************



















end module mod_test_utilities
