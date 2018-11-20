module messenger
    use mod_kinds,      only: rk,ik
    use mod_constants,  only: IO_DESTINATION
    use mod_version,    only: get_git_hash
    use mod_chidg_mpi,  only: IRANK, GLOBAL_MASTER, ChiDG_COMM
    implicit none


    character(:), allocatable   :: line                         ! Line that gets assembled and written
    character(:), allocatable   :: color_begin, color_end
    character(2), parameter     :: default_delimiter = '  '     ! Delimiter of line parameters
    character(:), allocatable   :: current_delimiter            ! Delimiter of line parameters
    integer                     :: default_column_width = 20    ! Default column width
    integer                     :: log_unit                         ! Unit of log file
    integer, parameter          :: max_msg_length = 300         ! Maximum width of message line
    integer                     :: msg_length = max_msg_length  ! Default msg_length
    logical                     :: log_initialized = .false.    ! Status of log file


contains



    !> Log initialization
    !!
    !!  Gets new available file unit and opens log file. 'log_unit' is a module 
    !!  variable that can be used throughout the module to access the log file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/2/2016
    !!
    !!-----------------------------------------------------------------------------------------
    subroutine log_init()

        logical         :: file_opened = .false.
        character(8)    :: date
        character(10)   :: time
        integer         :: ierr

        ! Open file
        inquire(file='chidg.log', opened=file_opened)
        if (.not. file_opened ) then
            open(newunit=log_unit, file='chidg.log', form='formatted', access='sequential', iostat=ierr)
            if (ierr /= 0) then
                print*, '************** WARNING ****************'
                print*, 'log_init: error opening log file.', ' iostat = ', ierr
                print*, '***************************************'
            end if
        end if


        ! Confirm log initialized
        log_initialized = .true.


        !
        ! Write log header
        !
        call date_and_time(date,time)

        call write_line('-----------------------------------------------------', io_proc=GLOBAL_MASTER)
        call write_line(' ', io_proc=GLOBAL_MASTER)
        call write_line('Date:      ', date(:4)//" "//date(5:6)//" "//date(7:8), ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Time:      ', time(:2)//":"//time(3:4)//":"//time(5:6), ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Git commit: ', get_git_hash(), io_proc=GLOBAL_MASTER)
        call write_line(' ', io_proc=GLOBAL_MASTER)
        call write_line('-----------------------------------------------------', io_proc=GLOBAL_MASTER)



    end subroutine log_init
    !******************************************************************************************






    !> Log finalization
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/2/2016
    !!
    !!-----------------------------------------------------------------------------------------
    subroutine log_finalize()

        logical :: file_opened = .false.
        logical :: file_exists = .false.
        integer :: ierr

        !
        ! Close file
        !
        inquire(log_unit, exist=file_exists, opened=file_opened, iostat=ierr)
        !if (ierr /= 0) then
        !    print*, "************** WARNING ****************"
        !    print*, "Error inquiring about log 'chidg.log'. ", " ierr: ", ierr, " File exists: ", file_exists, " File opened: ", file_opened
        !    print*, "***************************************"
        !end if

        if (file_opened) close(log_unit)

    end subroutine log_finalize
    !******************************************************************************************









    !> Message routine for handling warnings and errors. Reports file name, line number,
    !! and warn/error message. This would usually not be called directly. Rather, use
    !! the macro defined in message.h that automatically inserts filename and linenumber.
    !!
    !! 'level' controls the action.
    !! - Warn            :: 1
    !! - Non-fatal error :: 2
    !! - Fatal error     :: 3
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/2/2016
    !!
    !!  @param[in]  pathname    Path and name of the file that the message is coming from.
    !!  @param[in]  linenum     Line number in the file that 'message' was called from.
    !!  @param[in]  sig         Signal level of the message. Defined above.
    !!  @param[in]  msg         Accompanying message to print.
    !!  @param[in]  info_one    Optional auxiliary information to be reported.
    !!  @param[in]  info_two    Optional auxiliary information to be reported.
    !!
    !------------------------------------------------------------------------------------------
    subroutine message(pathname, linenum, sig, user_msg, info_one, info_two, info_three, dev_msg)
        character(*), intent(in)                        :: pathname
        integer(ik),  intent(in)                        :: linenum
        integer(ik),  intent(in)                        :: sig
        character(*), intent(in)                        :: user_msg
        class(*),     intent(in), target,   optional    :: info_one
        class(*),     intent(in), target,   optional    :: info_two
        class(*),     intent(in), target,   optional    :: info_three
        character(*), intent(in),           optional    :: dev_msg

        integer                         :: iaux, pathstart
        integer(ik)                     :: ierr, chidg_signal_length
        character(len=:), allocatable   :: subpath, temppath, genstr
        class(*), pointer               :: auxdata => null()
        character(100)                  :: warnstr, errstr, killstr, starstr, linechar, &
                                           dashstr, blankstr, oopsstr, msgstr
        logical                         :: print_info_one   = .false.
        logical                         :: print_info_two   = .false.
        logical                         :: print_info_three = .false.



        oopsstr  = '                                         ... Oops :/                                           '
        msgstr   = '                                        ChiDG Message                                          '
        warnstr  = '******************************************  Warning  ******************************************'
        errstr   = '**************************************  Non-fatal error  **************************************'
        killstr  = '****************************************  Fatal error  ****************************************'
        starstr  = '***********************************************************************************************'
        dashstr  = '-----------------------------------------------------------------------------------------------'
        blankstr = new_line('A')



        !
        ! Set message length 
        !
        chidg_signal_length = 105

        !
        ! Chop off unimportant beginning of file path
        !
        temppath = pathname
        pathstart = index(temppath, 'src/')
        if (pathstart == 0) then
            subpath = temppath
        else
            subpath = temppath(pathstart:len(pathname))
        end if


        !
        ! Assemble string including file name and line number
        !
        write(linechar, '(i10)') linenum
        genstr = trim(subpath) // ' at ' // adjustl(trim(linechar))


        !
        ! Print message header
        !
        call write_line(blankstr, width=chidg_signal_length)
        call write_line(trim(dashstr))
        select case (sig)
            case (0)    ! Normal message  -- Code continues
                call write_line(trim(msgstr),   color='aqua', ltrim=.false., bold=.true., width=chidg_signal_length)
            case (1)    ! Warning message -- Code continues
                call write_line(trim(warnstr),  color='aqua', ltrim=.false., bold=.true., width=chidg_signal_length)
            case (2)    ! Non-Fatal Error -- Code continues
                call write_line(trim(errstr),   color='aqua', ltrim=.false., bold=.true., width=chidg_signal_length)
            case (3)    ! Fatal Error     -- Code terminates
                call write_line(trim(killstr),  color='aqua', ltrim=.false., bold=.true., width=chidg_signal_length)
            case (4)    ! Oops Error      -- Code terminates
                call write_line(trim(oopsstr),  color='aqua', ltrim=.false., bold=.true., width=chidg_signal_length)
            case default
                print*, "Messenger:message -- message code not recognized"
                stop
        end select
        call write_line(trim(dashstr), width=chidg_signal_length)


        ! 
        ! Print USER message
        !
        call write_line(trim(blankstr), width=chidg_signal_length)
        call write_line('For users:',   color='blue', bold=.true., width=chidg_signal_length)
        call write_line(trim(user_msg), color='blue', width=chidg_signal_length-10)
        call write_line(trim(blankstr), width=chidg_signal_length)

        !
        ! Print DEVELOPER message
        !
        if (present(dev_msg)) then
            call write_line('For developers:', color='red', bold=.true., width=chidg_signal_length)
            call write_line(trim(dev_msg),     color='red', width=chidg_signal_length-10)
            call write_line(trim(blankstr), width=chidg_signal_length)
        end if

        !
        ! Print File/Line information
        !
        call write_line('Information about the message:', bold=.true., width=chidg_signal_length)
        call write_line(trim(genstr), width=chidg_signal_length)
        call write_line(blankstr, width=chidg_signal_length)



        !
        ! Loop through auxiliary variables. If present, try to print.
        !
        do iaux = 1,3

            print_info_one   = ( present(info_one)   .and. (iaux == 1) )
            print_info_two   = ( present(info_two)   .and. (iaux == 2) )
            print_info_three = ( present(info_three) .and. (iaux == 3) )

            if ( print_info_one )   auxdata => info_one
            if ( print_info_two )   auxdata => info_two
            if ( print_info_three ) auxdata => info_three

            !
            ! auxdata pointer is used to point to current auxiliary data variable and then go through the available IO types
            !
            if ( associated(auxdata) ) then
                call write_line('Information about the message:', bold=.true., width=chidg_signal_length)

                select type(auxdata)
                    type is(integer)
                        call write_line(auxdata, width=chidg_signal_length)
                    type is(integer(8))
                        call write_line(auxdata, width=chidg_signal_length)
                    type is(real)
                        call write_line(auxdata, width=chidg_signal_length)
                    type is(real(8))
                        call write_line(auxdata, width=chidg_signal_length)
                    type is(character(*))
                        call write_line(auxdata, width=chidg_signal_length)
                    type is(logical(2))
                        call write_line(auxdata, width=chidg_signal_length)
                    type is(logical(4)) 
                        call write_line(auxdata, width=chidg_signal_length)
                    type is(logical(8))
                        call write_line(auxdata, width=chidg_signal_length)

                    class default
                        print*, '', "Data type not implemented for I/O in messege.f90"
                end select

            end if ! present(info_one)


            !
            ! Disassociate pointer so it doesn't try to print the same thing twice in some cases.
            !
            auxdata => null()

        end do ! iaux





        !
        ! Print message footer
        !
        call write_line(blankstr, width=chidg_signal_length)
        call write_line(dashstr, width=chidg_signal_length)



        !
        ! Select signal action
        !
        select case (sig)
            case (3,4)    ! Fatal Error -- Code terminates
                call log_finalize() !Make sure log file is flushed before everything gets killed.
                call chidg_abort()
                !stop
                !error stop


            case default

        end select


    end subroutine message
    !******************************************************************************************








    !>  This subroutine writes a line to IO that is composed of 8 optional incoming variables.
    !!  This is accomplished by first passing each component to the 'add_to_line' subroutine, 
    !!  which assembles the data into the 'line' module-global variable. Then, the 'send_line' 
    !!  subroutine is called to handle the destination of the line to either the screen, a 
    !!  file, or both.
    !!
    !!
    !!  Some Options:
    !!      columns = .true. / .false.
    !!      ltrim   = .true. / .false.
    !!      bold    = .true. / .false.
    !!      color   = 'black', 'red', 'green', 'yellow', 'blue', 'purple', 'aqua', 'pink', 'none'
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/2/2016
    !!
    !!  @param[in]  a-h             Optional polymorphic variables that can be used to compose a line sent to IO.
    !!  @param[in]  delimiter       Optional delimiter that is used to separate line components. Default is set to ' '
    !!  @param[in]  columns         Logical optional to indicate if incoming arguments should be aligned in columns.
    !!  @param[in]  column_width    Optional integer indicating the column width if columns was indicated.
    !!  @param[in]  color           String indicating a color for the text
    !!  @param[in]  ltrim           Logical indicating to trim the string of empty characters
    !!  @param[in]  bold            Logical to output text in bold
    !!  @param[in]  silence         Logical, allows writing to be turned on or off
    !!  @param[in]  io_proc         Integer specifying MPI Rank responsible for outputing a message
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_line(a,b,c,d,e,f,g,h,delimiter,columns,column_width,width,color,ltrim,bold,silence,io_proc,handle)
        class(*),           intent(in), target, optional        :: a
        class(*),           intent(in), target, optional        :: b
        class(*),           intent(in), target, optional        :: c
        class(*),           intent(in), target, optional        :: d
        class(*),           intent(in), target, optional        :: e
        class(*),           intent(in), target, optional        :: f
        class(*),           intent(in), target, optional        :: g
        class(*),           intent(in), target, optional        :: h
        character(*),       intent(in),         optional        :: delimiter
        logical,            intent(in),         optional        :: columns
        integer(ik),        intent(in),         optional        :: column_width
        integer(ik),        intent(in),         optional        :: width
        character(*),       intent(in),         optional        :: color
        logical,            intent(in),         optional        :: ltrim
        logical,            intent(in),         optional        :: bold
        logical,            intent(in),         optional        :: silence
        integer(ik),        intent(in),         optional        :: io_proc
        integer(ik),        intent(in),         optional        :: handle

        class(*), pointer   :: auxdata => null()

        integer :: iaux
        logical :: print_info_one,   print_info_two,   print_info_three, &
                   print_info_four,  print_info_five,  print_info_six,   &
                   print_info_seven, print_info_eight, proc_write


        
        !
        ! Decide if io_proc is writing or if all are writing
        !
        if ( present(io_proc) ) then
            if ( IRANK == io_proc ) then
                proc_write = .true.
            else
                proc_write = .false.
            end if

        else
            proc_write = .true.
        end if


        !
        ! Handle 'silence' input logical. 
        !   - proc_write only needs modified if silence is requested,
        !     and if proc_write was already set to true. In this case,
        !     silence requests that it be set back to false.
        !
        if ( present(silence) ) then
            if (proc_write .and. silence) proc_write = .false.
        end if


        !
        ! Set width
        !
        if (present(width)) msg_length = width




        if ( proc_write ) then

            !
            ! Loop through variables and compose line to write
            !
            do iaux = 1,8

                print_info_one   = ( present(a) .and. (iaux == 1) )
                print_info_two   = ( present(b) .and. (iaux == 2) )
                print_info_three = ( present(c) .and. (iaux == 3) )
                print_info_four  = ( present(d) .and. (iaux == 4) )
                print_info_five  = ( present(e) .and. (iaux == 5) )
                print_info_six   = ( present(f) .and. (iaux == 6) )
                print_info_seven = ( present(g) .and. (iaux == 7) )
                print_info_eight = ( present(h) .and. (iaux == 8) )

                if ( print_info_one   )  auxdata => a
                if ( print_info_two   )  auxdata => b
                if ( print_info_three )  auxdata => c
                if ( print_info_four  )  auxdata => d
                if ( print_info_five  )  auxdata => e
                if ( print_info_six   )  auxdata => f
                if ( print_info_seven )  auxdata => g
                if ( print_info_eight )  auxdata => h



                ! Add data to line
                if ( associated(auxdata) ) then
                    call add_to_line(auxdata,delimiter,columns,column_width,color,ltrim,bold)
                end if

                ! Unassociate pointer
                auxdata => null()

            end do


            ! Send line to output
            call send_line(handle=handle)

        end if ! proc_write


        ! ReSet width
        if (present(width)) msg_length = max_msg_length

    end subroutine write_line
    !******************************************************************************************








    !> Adds data to the module-global 'line' character string
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/2/2016
    !!
    !!  @param[in]  linedata        Polymorphic data component that gets converted to a string and added to the IO line
    !!  @param[in]  delimiter       Optional delimiter that is used to separate line components. Default is set to ' '
    !!  @param[in]  columns         Logical optional to indicate if incoming arguments should be aligned in columns.
    !!  @param[in]  column_width    Optional integer indicating the column width if columns was indicated.
    !!
    !------------------------------------------------------------------------------------------
    subroutine add_to_line(linedata,delimiter,columns,column_width,color,ltrim,bold,silent)
        class(*),       intent(in)              :: linedata
        character(*),   intent(in), optional    :: delimiter
        logical,        intent(in), optional    :: columns
        integer(ik),    intent(in), optional    :: column_width
        character(*),   intent(in), optional    :: color
        logical,        intent(in), optional    :: ltrim
        logical,        intent(in), optional    :: bold
        logical,        intent(in), optional    :: silent

        character(100)                  :: write_internal
        character(len=:),   allocatable :: temp, temp_a, temp_b
        integer(ik)                     :: current_width, extra_space, test_blank, width
        logical                         :: blank_line, silent_status


        !
        ! Initialize temp
        !
        temp = ''


        !
        ! Select delimiter
        !
        if (  present(delimiter) ) then
            current_delimiter = delimiter
        else
            current_delimiter = default_delimiter
        end if



        !
        ! Set color
        !
        if ( present(color) .and. (.not. present(bold)) ) then
            call set_color(color)
        else if ( (.not. present(color)) .and. present(bold) ) then
            call set_color('none', bold)
            !call set_color(bold=bold)
        else if ( present(color) .and. present(bold) ) then
            call set_color(color, bold)
        else
            call set_color('none')
        end if



        !
        ! Add to line. Since variable is polymorphic, we have to test for each type and handle
        ! appropriately. Numeric data gets first written to a string variable and then concatatenated to 
        ! the module-global 'line' variable.
        !
        select type(linedata)

            type is(character(len=*))
                temp = linedata

            type is(integer)
                if ( linedata == 0 ) then
                    write_internal = '0'
                else
                    write(write_internal, '(I10.0)') linedata
                end if
                temp = write_internal
            type is(integer(8))
                if ( linedata == 0 ) then
                    write_internal = '0'
                else
                    write(write_internal, '(I10.0)') linedata
                end if
                temp = write_internal

            type is(real)
                if (abs(linedata) > 0.1) then
                    write(write_internal, '(F24.14)') linedata
                else
                    write(write_internal, '(E24.14)') linedata
                end if
                temp = write_internal

            type is(real(8))
                if (abs(linedata) < 0.1) then
                    write(write_internal, '(E24.14)') linedata
                else if ( (abs(linedata) > 0.1) .and. (abs(linedata) < 1.e9) ) then
                    write(write_internal, '(F24.14)') linedata
                else
                    write(write_internal, '(E24.14)') linedata
                end if
                temp = write_internal

            type is(logical(1))
                if (linedata) then
                    temp = 'True'
                else
                    temp = 'False'
                end if

            type is (logical(2))
                if (linedata) then
                    temp = 'True'
                else
                    temp = 'False'
                end if

            type is (logical(4))
                if (linedata) then
                    temp = 'True'
                else
                    temp = 'False'
                end if

            class default
                print*, 'Error: no IO rule for provided data in add_to_line'
                stop
        end select


        !
        ! Test for blank line
        !
        test_blank = verify(temp, set=' ')
        if ( test_blank == 0 ) then
            blank_line = .true.
        else
            blank_line = .false.
        end if


        !
        ! Rules for neatening up the string. Check blank string. Check ltrim.
        !
        if ( blank_line ) then
            temp_a = temp   ! blank line, dont do any modification.

        else if ( present(ltrim) ) then
            if ( ltrim ) then
                temp_a = trim(adjustl(temp))    ! trim line if explicitly requested.
            else 
                temp_a = temp                   ! explicitly requested to not trim line.
            end if

        else
            temp_a = trim(adjustl(temp))        ! default, trim the line.
        end if





        !
        ! Append spaces for column alignment
        !
        if ( present(columns) ) then
            if (columns) then

                if (present(column_width)) then
                    width = column_width
                else
                    width = default_column_width
                end if

                current_width = len_trim(temp_a)  ! length without trailing blanks
                extra_space = width - current_width

                !
                ! Add spaces on front and back. Could cause misalignment with dividing integer by 2.
                !
                do while ( len(temp_a) < width )
                    temp_a = ' '//temp_a//' '
                end do

                !
                ! Make sure we are at exactly width. Could have gone over the the step above.
                !
                temp_b = temp_a(1:width)

                 
            end if
        else
            
            temp_b = temp_a

        end if



        ! Detect silence
        if (present(silent)) then
            silent_status = silent
        else
            silent_status = .false.
        end if

        ! Handle silence
        if (.not. silent_status) then
            ! Append new text to line
            line = line//color_begin//temp_b//color_end

            ! Append delimiter
            line = line//current_delimiter
        end if


    end subroutine add_to_line
    !******************************************************************************************









    !>  Handles sending module-global 'line' string to a destination of either the screen, 
    !!  a file, or both. Is is determined by the IO_DESTINATION variable from mod_constants.
    !!
    !!  Line wrapping is also handled, set by the module parameter 'msg_length'.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/3/2016
    !!
    !------------------------------------------------------------------------------------------
    subroutine send_line(silent,handle)
        logical,        intent(in), optional    :: silent
        integer(ik),    intent(in), optional    :: handle

        integer :: delimiter_size
        integer :: line_size
        integer :: line_trim
        integer :: lstart, lend, section

        character(:),   allocatable :: writeline, file_line
        integer                     :: section_length
        logical                     :: send
        integer(ik) :: write_handle


        !
        ! Handle optional input
        !
        write_handle = log_unit
        if (present(handle)) write_handle = handle



        !
        ! Detect silent or not
        !
        send = .true.
        if (present(silent)) then
            if (silent) send = .false.
        end if


        !
        ! Enable silent
        !
        if (send) then

            !
            ! Get line section length
            !
            if ( len(line) > msg_length ) then
                section_length = msg_length
            else
                section_length = len(line)
            end if


            !
            ! Get line/delimiter sizes
            !
            delimiter_size = len(current_delimiter)
            line_size      = len(line)
            line_trim      = line_size - delimiter_size



            !
            ! Remove trailing delimiter
            !
            line = line(1:line_trim)



            !
            ! Handle line IO. Writes the line in chunks for line-wrapping until the entire 
            ! line has been processed.
            !
            writeline = line
            section = 1
            lend    = 0
            !do while ( lend /= len(line) ) 
            do while ( lend < len(line) ) 

                !
                ! Set position to start writing
                !
                lstart = lend + 1

                !
                ! Set position to stop writing
                !
                lend = lend + section_length

                ! Don't go out-of-bounds
                if (lend >= len(line)) then
                    lend = len(line)
                else
                    ! Move backwards until a word break so we don't split words when we wrap
                    do while ( (line(lend:lend) /= " ") .and. (lend > 1))
                        lend = lend-1
                    end do
                end if


                ! Make sure lend is valid and that we didn't back up too far.
                ! This might happen for a long file path that doens't have a blank.
                ! then the line wrapper backs up to space 0. In that case, we just write 
                ! the whole thing.
                if (lend == 1) lend = len(line)


                !
                ! Make sure to at least print something in case where was a really long solid string 
                ! and we stepped backwards too far.
                !
                if (lend < lstart) then
                    lend = lstart + section_length
                end if

                !
                ! Dont go out-of-bounds
                !
                if (lstart > len(line) ) then
                    exit
                end if
                if (lend >= len(line)) then
                    lend = len(line)
                end if


                !
                ! Get line for writing
                !
                writeline = line(lstart:lend)


                !
                ! Write to destination
                !
                if ( trim(IO_DESTINATION) == 'screen' ) then
                    print*, writeline


                else if ( trim(IO_DESTINATION) == 'file' ) then
                    if (log_initialized) then
                        file_line = remove_formatting(writeline)
                        write(write_handle,*) file_line
                    else
                        stop "Trying to write a line, but log file not inititlized. Call chidg%init('env')"
                    end if



                else if ( trim(IO_DESTINATION) == 'both' ) then
                    if (log_initialized) then
                        print*, writeline

                        file_line = remove_formatting(writeline)
                        write(write_handle,*) file_line

                    else
                        stop "Trying to write a line, but log file not inititlized. Call chidg%init('env')"
                    end if



                else
                    print*, "Error: value for IO_DESTINATION is invalid. Valid selections are 'screen', 'file', 'both'."

                end if


                !
                ! Next line chunk to write
                !
                section = section + 1

            end do ! len(line) > msg_length


            !
            ! Clear line
            !
            line = ''

        end if !silent


    end subroutine send_line
    !******************************************************************************************








    !>  Set line color.
    !!
    !!  ANSI Escape color strings:
    !!      color_begin string = [setting;setting;settingm
    !!      color_end   string = [m
    !!
    !!  achar(27) adds an escape character so these are recognizes as colorings
    !!
    !!  Note: the trailing  'm' in the beginning string. 
    !!  Note: setting = 1 adds bold
    !!  Note: setting = 30-36 are colors
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/3/2016
    !!
    !!  @param[in]  color   String indicating the color to set
    !!
    !-------------------------------------------------------------------------------------------
    subroutine set_color(color,bold)
        character(*),   optional, intent(in)    :: color
        logical,        optional, intent(in)    :: bold

        color_begin = achar(27)//'['
        color_end   = achar(27)//'[m'

        
        !
        ! Add color if present
        !
        if (present(color)) then
            select case (color)
                case ('black')
                    color_begin = color_begin//'30'

                case ('red')
                    color_begin = color_begin//'31'

                case ('green')
                    color_begin = color_begin//'32'

                case ('yellow')
                    color_begin = color_begin//'33'

                case ('blue')
                    color_begin = color_begin//'34'

                case ('purple')
                    color_begin = color_begin//'35'

                case ('aqua')
                    color_begin = color_begin//'36'

                case ('pink')
                    color_begin = color_begin//'95'

                case ('none')
                    color_begin = color_begin//''

                case default
                    color_begin = color_begin//''
                    call message(__FILE__,__LINE__,1, "set_color: unrecognized color string.",color) ! send warning
            end select
        end if



        !
        ! Add bold if present
        !
        if (present(bold)) then
            if (bold) then
                color_begin = color_begin//";1"
            end if
        end if



        !
        ! Terminate color_begin
        !
        color_begin = color_begin//'m'


    end subroutine set_color
    !******************************************************************************************








    !>  Given a character-array, search for color/formatting strings and remove them.
    !!
    !!  Useful for writing to file, where we don't want to litter the file with ASCI
    !!  formatting strings.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/20/2017
    !!
    !!
    !------------------------------------------------------------------------------------------
    function remove_formatting(string) result(string_out)
        character(*),   intent(in)  :: string

        character(:),   allocatable :: string_out
        integer(ik)                 :: format_begin, format_end
        logical                     :: contains_formatting 

        !
        ! Initialize string_out
        !
        string_out = string

        
        contains_formatting = ( index(string_out,achar(27)) /= 0 )
        do while (contains_formatting)


            !
            ! Check contains formatting
            !
            format_begin = index(string_out,achar(27))
            if (format_begin /= 0) then

                !
                ! Find terminating string location
                !
                format_end = format_begin
                do while ( string_out(format_end:format_end) /= 'm' )
                    format_end = format_end + 1
                    if (format_end > len(string_out)) exit
                end do
            

                !
                ! Remove formatting entry
                !
                if ( (format_begin == 1) .and. (format_end == len(string_out)) ) then
                    string_out = ' '
                else if ( (format_begin == 1) .and. (format_end /= len(string_out)) ) then
                    string_out = string_out(format_end+1:)
                else if ( (format_begin /= 1) .and. (format_end == len(string_out)) ) then
                    string_out = string_out(1:format_begin-1)
                else if ( (format_begin /= 1) .and. (format_end /= len(string_out)) ) then
                    string_out = string_out(1:format_begin-1)//string_out(format_end+1:)
                else
                    print*, 'remove_formatting: unexpected case for removing formatting from output strings.'
                end if


            end if

            !
            ! Check exit condition
            !
            contains_formatting = ( index(string_out,achar(27)) /= 0 )

        end do !contains_formatting


    end function remove_formatting
    !******************************************************************************************






    !>
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_abort()
        integer(ik) :: ierr

        !
        ! Abort MPI library
        !
        call MPI_Abort(ChiDG_COMM,ierr)

        ! Send error signal to unix process.
        ! Important for tests that fail because of setup problems. 
        ! This returns an error status to the ctest runner in 'make test'
        ! 
        call exit(-1)


    end subroutine chidg_abort
    !******************************************************************************************



end module messenger
