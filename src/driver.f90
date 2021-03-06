!>  Chimera-based, discontinuous Galerkin equation solver
!!
!!  This program is designed to solve partial differential equations,
!!  and systems of partial differential equations, using the discontinuous
!!  Galerkin method for spatial discretization using overset grids to
!!  represent the simulation domain.
!!
!!  @author Nathan A. Wukie
!!  @date   1/31/2016
!!
!---------------------------------------------------------------------------------------------
program driver
#include <messenger.h>
    use type_chidg,                 only: chidg_t
    use type_function,              only: function_t
    use mod_function,               only: create_function
    use mod_file_utilities,         only: delete_file
    use mod_string,                 only: str
    use mod_version,                only: ChiDG_VERSION_MAJOR, ChiDG_VERSION_MINOR, ChiDG_VERSION_PATCH, get_git_hash
    use mpi_f08,                    only: MPI_AllReduce, MPI_INTEGER4, MPI_MAX, MPI_CHARACTER, MPI_LOGICAL
    use mod_io

    ! Actions
    use mod_chidg_edit,         only: chidg_edit
    use mod_chidg_convert,      only: chidg_convert
    use mod_chidg_forces,       only: chidg_forces
    use mod_chidg_adjoint,      only: chidg_adjoint
    use mod_chidg_adjointx,     only: chidg_adjointx
    use mod_chidg_adjointbc,    only: chidg_adjointbc
    use mod_chidg_clone,        only: chidg_clone
    use mod_chidg_dot,          only: chidg_dot_fd, chidg_dot_cd, chidg_dot
    use mod_chidg_post_hdf2tec, only: chidg_post_hdf2tec
    use mod_chidg_post_hdf2vtk, only: chidg_post_hdf2vtk
    use mod_tutorials,          only: tutorial_driver
    use mod_euler_eigenmodes,   only: compute_euler_eigenmodes

    ! Variable declarations
    implicit none
    type(chidg_t)                               :: chidg
    integer                                     :: narg, ierr, ifield
    integer(ik)                                 :: nfields, nfields_global
    character(len=1024)                         :: chidg_action, filename, grid_file, solution_file, file_a, file_b, file_in, &
                                                   pattern, tutorial, patch_group, adjoint_pattern, primal_pattern, fd_delta, &
                                                   mesh_sensitivities, original_grid, perturbed_grid, pos_perturbed_grid,     &
                                                   neg_perturbed_grid, func_sensitivities
    character(len=10)                           :: time_string
    character(:),                   allocatable :: command, tmp_file
    class(function_t),              allocatable :: fcn
    logical                                     :: run_chidg_action, file_exists, exit_signal, call_shutdown


    ! Check for command-line arguments
    narg = command_argument_count()

    ! Get potential 'action'
    call get_command_argument(1,chidg_action)
    

    run_chidg_action = .false.
    if (trim(chidg_action) == '2tec'       .or. &
        trim(chidg_action) == '2vtk'       .or. &
        trim(chidg_action) == 'convert'    .or. &
        trim(chidg_action) == 'edit'       .or. &
        trim(chidg_action) == 'clone'      .or. &
        trim(chidg_action) == 'forces'     .or. &
        trim(chidg_action) == 'adjoint'    .or. &
        trim(chidg_action) == 'adjointx'   .or. &
        trim(chidg_action) == 'adjointbc'  .or. &
        trim(chidg_action) == 'inputs'     .or. &
        trim(chidg_action) == 'tutorial'   .or. &
        trim(chidg_action) == 'dot'        .or. &
        trim(chidg_action) == 'dot-fd'      .or. &
        trim(chidg_action) == 'dot-cd'      .or. &
        trim(chidg_action) == 'tutorial'   .or. &
        trim(chidg_action) == '-v'         .or. & 
        trim(chidg_action) == '-h') run_chidg_action = .true.


    ! Execute ChiDG calculation
    if (.not. run_chidg_action) then


        ! Initialize ChiDG environment
        call chidg%start_up('mpi')
        call chidg%start_up('namelist')
        call chidg%start_up('core')

        ! Check input files are valid
        inquire(file=trim(gridfile), exist=file_exists)
        if (.not. file_exists) call chidg_signal_one(FATAL,"open_file_hdf: Could not find file.",trim(gridfile))
        if (trim(solutionfile_in) /= 'none') then
            inquire(file=trim(solutionfile_in), exist=file_exists)
            if (.not. file_exists) call chidg_signal_one(FATAL,"open_file_hdf: Could not find file.",trim(solutionfile_in))
        end if

        ! Set ChiDG Algorithms, Accuracy
        call chidg%set('Time Integrator' , algorithm=time_integrator                   )
        call chidg%set('Nonlinear Solver', algorithm=nonlinear_solver, options=noptions)
        call chidg%set('Linear Solver'   , algorithm=linear_solver,    options=loptions)
        call chidg%set('Preconditioner'  , algorithm=preconditioner                    )
        call chidg%set('Solution Order'  , integer_input=solution_order                )

        ! Read grid and boundary condition data
        call chidg%read_mesh(gridfile,storage='primal storage')

        ! Initialize solution
        !   1: 'none', init fields with values from mod_io module variable initial_fields(:)
        !   2: read initial solution from ChiDG hdf5 file
        if (solutionfile_in == 'none') then
            call create_function(fcn,'constant')
            
            nfields = 0
            if (chidg%data%mesh%ndomains() > 0) nfields = chidg%data%mesh%domain(1)%nfields
            call MPI_AllReduce(nfields,nfields_global,1,MPI_INTEGER4,MPI_MAX,ChiDG_COMM,ierr)

            do ifield = 1,nfields_global
                call fcn%set_option('val',initial_fields(ifield))
                call chidg%data%sdata%q_in%project(chidg%data%mesh,fcn,ifield)
            end do

        else
            call chidg%read_fields(solutionfile_in)
        end if


        ! Run ChiDG simulation
        call chidg%reporter('before')
        call chidg%run(write_initial=initial_write, write_final=final_write, write_tecio=tecio_write, write_report=.true.)
        call chidg%reporter('after')


        ! Close ChiDG
        call chidg%shut_down('core')
        call chidg%shut_down('mpi')





    ! If not running calculation, try and run chidg 'action'
    else 

        ! Get 'action'
        call get_command_argument(1,chidg_action)

        ! Default, call shutdown procedures at end
        call_shutdown = .true.

        ! Select 'action'
        select case (trim(chidg_action))

            !>  Print version and git data
            !!
            !!  @author Nathan A. Wukie (AFRL)
            !!  @date   11/20/2019
            !!
            !----------------------------------------------------------------------------
            case ('-v')
                print*, "------------------------------------------------------"
                print*, "chidg: An overset discontinuous Galerkin framework"
                print*, "   version:  ", trim(str(ChiDG_VERSION_MAJOR))//"."//trim(str(ChiDG_VERSION_MINOR))//"."//trim(str(ChiDG_VERSION_PATCH))
                print*, "   git hash: ", get_git_hash()
                print*, "------------------------------------------------------"
                call_shutdown = .false.
            !*****************************************************************************

            !>  Print help data
            !!
            !!  @author Nathan A. Wukie (AFRL)
            !!  @date   11/20/2019
            !!
            !----------------------------------------------------------------------------
            case ('-h')
                print*, "------------------------------------------------------"
                print*, "chidg: An overset discontinuous Galerkin framework"
                print*, "[usage]"
                print*, "   chidg                               [run analysis. expects to find chidg.nml]"
                print*, "   chidg 2tec file.h5                  [create tecplot .szplt visualization file from .h5 chidg data. Can be run in parallel.]"
                print*, "   chidg 2vtk file.h5                  [create vtk visualization file from .h5 chidg data. Must be run in serial.]"
                print*, "   chidg convert file.x                [convert .x (Unformatted, Multi-Block, Double-Precision Plot3D file) to chidg .h5 grid file. Must be run in serial.]"
                print*, "   chidg edit file.h5                  [edit chidg file.h5 setup (boundary conditions, equations, etc.). Must be run in serial.]"
                print*, "   chidg clone template.h5 stamp.h5    [clone chidg template.h5 configuration to stamp.h5. Must be run in serial.]"
                print*, "   chidg inputs                        [write out chidg.nml input file with all valid parameters. Must be run in serial.]"
                print*, "   chidg tutorial tutorial_name        [run chidg tutorial. tutorials: smooth_bump]"
                print*, "------------------------------------------------------"
                call_shutdown = .false.
            !*****************************************************************************



            !>  ChiDG:convert   src/actions/convert
            !!
            !!  Convert Multi-block, Unformatted, Double-Precision, Plot3D grids to
            !!  ChiDG-formatted HDF5 file.
            !!
            !!  NOTE: this routine handles agglomeration of linear elements to form 
            !!  higher-order elements.
            !!
            !!  Command-Line:
            !!  --------------------
            !!  chidg convert myfile.x
            !!
            !!  Produces:
            !!  --------------------
            !!  myfile.h5
            !!
            !----------------------------------------------------------------------------
            case ('convert')
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                if (narg /= 2) call chidg_signal(FATAL,"The 'convert' action expects: chidg convert filename.x")
                call get_command_argument(2,filename)
                call chidg_convert(trim(filename))

            !*****************************************************************************



            !>  ChiDG:edit  src/actions/edit
            !!
            !!  Edit a ChiDG HDF5 file. Edit equations, boundary conditions + settings,
            !!  and patches.
            !!
            !!  Command-Line:
            !!  ---------------------
            !!  chidg edit myfile.h5
            !!
            !----------------------------------------------------------------------------
            case ('edit')
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                call get_command_argument(2,filename)
                if (narg < 2) call chidg_signal(FATAL,"The 'edit' action was called with too few arguments. Try: chidg edit filename.h5")
                if (narg > 2) call chidg_signal(FATAL,"The 'edit' action was called with too many arguments. Try: chidg edit filename.h5")
                call chidg_edit(trim(filename))

            !*****************************************************************************




            case ('2tec')
            !>  ChiDG:post  src/actions/post
            !!
            !!  Post-process solution files for visualization (tecplot format)
            !!
            !!  Command-Line MODE 1: Single-file
            !!  --------------------------------
            !!
            !!     Command-line:                    Output:
            !!  chidg post myfile.h5       myfile.plt (Tecplot-readable)
            !!
            !!  Command-Line MODE 2: Multi-file
            !!  --------------------------------
            !!  In the case where there are several files that need processed,
            !!  wildcards can be passed in, but must be wrapped in quotes " ".
            !!
            !!  Files: myfile_0.1000.h5, myfile_0.2000.h5, myfile_0.3000.h5
            !!
            !!     Command-line:                Output:
            !!  chidg post "myfile*"        myfile_0.1000.plt
            !!                              myfile_0.2000.plt
            !!                              myfile_0.3000.plt
            !!
            !!---------------------------------------------------------------------------
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                if (narg /= 2) call chidg_signal(FATAL,"The '2tec' action expects: chidg 2tec file.h5")

                if (IRANK == GLOBAL_MASTER) then
                    call date_and_time(time=time_string)
                    tmp_file = 'chidg_2tec_files'//time_string//'.txt'
                    call get_command_argument(2,pattern)
                    command = 'ls '//trim(pattern)//' > '//tmp_file
                    call system(command)

                    ! Make sure file syncs with filesystem first
                    file_exists = .false.
                    do while (.not. file_exists)
                        inquire(file=tmp_file,exist=file_exists)
                        call sleep(1)
                    end do

                    open(7,file=tmp_file,action='read')
                end if
            

                exit_signal = .false.
                do

                    if (IRANK == GLOBAL_MASTER) then
                        read(7,fmt='(a)', iostat=ierr) solution_file
                        if (ierr /= 0) exit_signal = .true.
                    end if

                    call MPI_BCast(solution_file,1024,MPI_CHARACTER,GLOBAL_MASTER,ChiDG_COMM,ierr)
                    if (ierr /= 0) call chidg_signal(FATAL,'chidg 2tec: error broadcasting solution file.')

                    call MPI_BCast(exit_signal,1,MPI_LOGICAL,GLOBAL_MASTER,ChiDG_COMM,ierr)
                    if (ierr /= 0) call chidg_signal(FATAL,'chidg 2tec: error broadcasting exit signal.')
                        
                    if (exit_signal) exit



                    call chidg_post_hdf2tec(chidg,trim(solution_file),trim(solution_file))

                    ! Release existing data
                    call chidg%data%release()

                end do


                ! Clean up
                if (IRANK == GLOBAL_MASTER) then
                    close(7)
                    call delete_file(tmp_file)
                end if

            !*****************************************************************************



            case ('2vtk')
            !>  ChiDG:post  src/actions/post
            !!
            !!  Post-process solution files for visualization (vtk format).
            !!
            !!  Command-Line MODE 1: Single-file
            !!  --------------------------------
            !!
            !!     Command-line:                    Output:
            !!  chidg post myfile.h5       myfile_itime_idom_itimestep.vtu (Paraview-readable)
            !!
            !!  Command-Line MODE 2: Multi-file
            !!  --------------------------------
            !!  In the case where there are several files that need processed,
            !!  wildcards can be passed in, but must be wrapped in quotes " ".
            !!
            !!  Files: myfile_0.1000.h5, myfile_0.2000.h5, myfile_0.3000.h5
            !!
            !!     Command-line:                Output:
            !!  chidg post "myfile*"        myfile_0_0_1.vtu
            !!                              myfile_0_0_2.vtu
            !!                              myfile_0_0_3.vtu
            !!
            !!---------------------------------------------------------------------------
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                if (narg /= 2) call chidg_signal(FATAL,"The '2vtk' action expects: chidg 2vtk file.h5")

                call date_and_time(time=time_string)
                tmp_file = 'chidg_2vtk_files'//time_string//'.txt'
                call get_command_argument(2,pattern)
                command = 'ls '//trim(pattern)//' > '//tmp_file
                call system(command)
            

                open(7,file=tmp_file,action='read')
                do
                    read(7,fmt='(a)', iostat=ierr) solution_file
                    if (ierr /= 0) exit
                    call chidg_post_hdf2vtk(trim(solution_file), trim(solution_file))
                end do
                close(7)

                call delete_file(tmp_file)
            !*****************************************************************************


    
            !>  ChiDG:clone src/actions/clone
            !!
            !!  Clone a ChiDG-file configuration from one file to another.
            !!
            !!  Command-Line:
            !!  ------------------------
            !!  chidg clone source.h5 target.h5
            !!
            !!  MODE1: Copy boundary condition state groups AND patch attributes 
            !!         (assumes the grid domain/topology/names match from source to target.
            !!  MODE2: Copy boundary condition state groups ONLY
            !!  MODE3: Copy patch attributes ONLY
            !!         (assumes the grid domain/topology/names match from source to target.
            !!
            !-----------------------------------------------------------------------------
            case ('clone')
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                if (narg /= 3) call chidg_signal(FATAL,"The 'clone' action expects: chidg clone source_file.h5 target_file.h5")
                call get_command_argument(2,file_a)
                call get_command_argument(3,file_b)
                call chidg_clone(trim(file_a),trim(file_b))

            !*****************************************************************************




            case ('forces')
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                if (narg /= 2) call chidg_signal(FATAL,"The 'forces' action expects to be called as: chidg forces solutionfile.h5")
                call get_command_argument(2,solution_file)
                call write_line('Enter patch group to integrate: ')
                read*, patch_group


                call date_and_time(time=time_string)
                tmp_file = 'chidg_forces_files'//time_string//'.txt'
                call get_command_argument(2,pattern)
                command = 'ls '//trim(pattern)//' > '//tmp_file
                call system(command)
            
                open(7,file=tmp_file,action='read')
                do
                    read(7,fmt='(a)', iostat=ierr) solution_file
                    if (ierr /= 0) exit
                    call chidg_forces(trim(solution_file),trim(patch_group))
                end do
                close(7)

                call delete_file(tmp_file)



            !>  ChiDG:adjoint src/actions/adjoint
            !!
            !!  Run an adjoint simulation 
            !!
            !!  Command-Line:
            !!  --------------------------------
            !!  chidg adjoint
            !!
            !!
            !!  The input flow solution is taken from the chidg.nml file
            !!
            !!      'solutionfile_in'
            !!
            !!  If there are multiple solution in time, such as:
            !!
            !!      flow_01.h5, flow_02.h5, flow_03.h5
            !!
            !!  simply set in chidg.nml:
            !!
            !!      'solutionfile_in' = flow.h5
            !!
            !!  ChiDG will search files with 
            !!
            !!      ls flow* 
            !!
            !!  WARNING: make sure that only the flow solutions in time are named with the same 
            !!           prefix.
            !!
            !-----------------------------------------------------------------------------
            case ('adjoint')
                if (narg /= 1) call chidg_signal(FATAL,"the 'adjoint' action does not expect other arguments.")

                call chidg_adjoint()
                call_shutdown = .false.
            !*****************************************************************************




            !>  ChiDG:adjointx src/actions/adjointx
            !!
            !!  Compute objective function sensitivities wrt grid nodes based on an 
            !!  adjoint solution.
            !!
            !!  Command-Line:
            !!  --------------------------------
            !!  chidg adjointx
            !!
            !!
            !!  The input flow and adjoint solutions are taken from the chidg.nml file
            !!
            !!      'solutionfile_in', 'adjoint_solutionfile_out'
            !!
            !!  If there are multiple solution in time, such as:
            !!
            !!      flow_01.h5, flow_02.h5, flow_03.h5 and adj_flow_01.h5, adj_flow_02.h5, adj_flow_03.h5 
            !!
            !!  simply set in chidg.nml:
            !!
            !!      'solutionfile_in' = flow.h5 and 'adjoint_solutionfile_out' = adj_flow.h5
            !!
            !!  ChiDG will search files with 
            !!
            !!      ls flow* and ls adj_flow* 
            !!
            !!  WARNING: make sure that only the flow solutions in time are named with the same 
            !!           prefix.
            !!
            !-----------------------------------------------------------------------------
            case ('adjointx')
                if (narg /=1) call chidg_signal(FATAL,"the 'adjointx' action does not expect other arguments.")
                call chidg_adjointx()
                call_shutdown = .false.
            !*****************************************************************************



            !>  ChiDG:adjointx src/actions/adjointbc
            !!
            !!  Compute objective function sensitivities wrt BC parameters based on an 
            !!  adjoint solution.
            !!
            !!  Command-Line:
            !!  --------------------------------
            !!  chidg adjointx
            !!
            !!
            !!  The input flow and adjoint solutions are taken from the chidg.nml file
            !!
            !!      'solutionfile_in', 'adjoint_solutionfile_out'
            !!
            !!  If there are multiple solution in time, such as:
            !!
            !!      flow_01.h5, flow_02.h5, flow_03.h5 and adj_flow_01.h5, adj_flow_02.h5, adj_flow_03.h5 
            !!
            !!  simply set in chidg.nml:
            !!
            !!      'solutionfile_in' = flow.h5 and 'adjoint_solutionfile_out' = adj_flow.h5
            !!
            !!  ChiDG will search files with 
            !!
            !!      ls flow* and ls adj_flow* 
            !!
            !!  WARNING: make sure that only the flow solutions in time are named with the same 
            !!           prefix.
            !!                                       
            !!
            !-----------------------------------------------------------------------------
            case ('adjointbc')
                if (narg /=1) call chidg_signal(FATAL,"the 'adjointbc' action does not expect other arguments.")
                call chidg_adjointbc()
                call_shutdown = .false.
            !*****************************************************************************


            !>  ChiDG:adjointx src/actions/dot
            !!
            !!  This action works actually with plot3d files (.x)
            !!
            !!  Computes the overall objecive function sensitivities wrt to a mesh parameter
            !!  using a .q (function file) for mesh sensitivites. 
            !!
            !!  Command-Line MODE 1: Single-file
            !!  --------------------------------
            !!  chidg dot functional_sensitivities.q  mesh_sensitivities.q
            !!                                       
            !!
            !-----------------------------------------------------------------------------
            case ('dot')
                if (narg /=3) call chidg_signal(FATAL,"The 'dot' action expects: chidg dot func_sensitivities.q mesh_sensitivities.q")
                call get_command_argument(2,func_sensitivities)
                call get_command_argument(3,mesh_sensitivities)
                call chidg_dot(trim(func_sensitivities),trim(mesh_sensitivities))
            !*****************************************************************************



            !>  ChiDG:adjointx src/actions/dot
            !!
            !!  This action works actually with plot3d files (.x)
            !!
            !!  Computes the overall objecive function sensitivities wrt to a mesh parameter
            !!  using the forward finite difference dX/dY (Y being the parameter). 
            !!
            !!  Command-Line MODE 1: Single-file
            !!  --------------------------------
            !!  chidg dot original.x perturbed.x mesh_sensitivities.q FD_delta
            !!
            !!  FD_delta is a real number (for instance 10e-05) used for computing
            !!  dX/dY by Forward Difference
            !!                                       
            !!
            !-----------------------------------------------------------------------------
            case ('dot-fd')
                if (narg /=5) call chidg_signal(FATAL,"The 'dotfd' action expects: chidg dotfd original.x perturbed.x mesh_sens.q FD_delta")
                call get_command_argument(2,original_grid)
                call get_command_argument(3,perturbed_grid)
                call get_command_argument(4,func_sensitivities)
                call get_command_argument(5,fd_delta)
                call chidg_dot_fd(trim(original_grid),trim(perturbed_grid),trim(func_sensitivities),fd_delta)
            !*****************************************************************************



            !>  ChiDG:adjointx src/actions/dot
            !!
            !!  This action works actually with plot3d files (.x)
            !!
            !!  Computes the overall objecive function sensitivities wrt to a mesh parameter
            !!  using the central finite difference dX/dY (Y being the parameter). 
            !!
            !!  Command-Line MODE 1: Single-file
            !!  --------------------------------
            !!  chidg dot neg_perturbed.x pos_perturbed.x mesh_sensitivities.q CD_delta
            !!
            !!  CD_delta is a real number (for instance 10e-05) used for computing
            !!  dX/dY by Central Difference ( that is h in (H_{i+1}-H_{i-1})/2h )
            !!                                       
            !!
            !-----------------------------------------------------------------------------
            case ('dot-cd')
                if (narg /=5) call chidg_signal(FATAL,"The 'dotcd' action expects: chidg dotcd neg_perturbed.x pos_perturbed.x mesh_sens.q CD_delta")
                call get_command_argument(2,neg_perturbed_grid)
                call get_command_argument(3,pos_perturbed_grid)
                call get_command_argument(4,func_sensitivities)
                call get_command_argument(5,fd_delta)
                call chidg_dot_cd(trim(neg_perturbed_grid),trim(pos_perturbed_grid),trim(func_sensitivities),fd_delta)
            !*****************************************************************************





            case ('inputs')
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                if (narg > 2) call chidg_signal(FATAL,"The 'inputs' action expects to be called as: chidg inputs")
                call write_namelist()


            case ('tutorial')
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                if (narg /= 2) call chidg_signal(FATAL,"The 'tutorial' action expects to be called as: chidg tutorial selected_tutorial.")
                call get_command_argument(2,tutorial)
                call tutorial_driver(trim(tutorial))

            case default
                call chidg%start_up('mpi')
                call chidg%start_up('core',header=.false.)
                call chidg_signal(FATAL,"We didn't understand the way chidg was called. Available chidg 'actions' are: 'edit' 'convert' 'post' 'inputs' and 'forces'.")
        end select


        if (call_shutdown) then
            call chidg%shut_down('core')
            call chidg%shut_down('mpi')
        end if



    end if




end program driver
