module m_obsNode
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:	 module m_obsNode
!   prgmmr:	 j guo <jguo@nasa.gov>
!      org:	 NASA/GSFC, Global Modeling and Assimilation Office, 610.3
!     date:	 2015-01-12
!
! abstract: basic obsNode functionalities interfacing the distributed grid
!
! program history log:
!   2015-01-12  j guo   - added this document block.
!   2016-05-18  j guo   - finished its initial polymorphic implementation.
!
!   input argument list: see Fortran 90 style document below
!
!   output argument list: see Fortran 90 style document below
!
! attributes:
!   language: Fortran 90 and/or above
!   machine:
!
!$$$  end subprogram documentation block

! module interface:

  use kinds, only: i_kind,r_kind
  use mpeu_util, only: tell,perr,die
  use mpeu_util, only: assert_
  implicit none
  private	! except
  public:: obsNode		! data structure

  type, abstract:: obsNode
     ! private

     ! - Being not "private", type(obsNode) allowes its type extentions
     !   to access its components without additional interfaces.
     ! - On the other hand, by turning private on, one can use the
     !   compiler to report where the components of this type have been
     !   used.

     class(obsNode),pointer :: llpoint => NULL()

     logical         :: luse =.false.         ! flag indicating if ob is used in pen.
     real(r_kind)    :: time = 0._r_kind      ! observation time in sec, relative to the time window
     real(r_kind)    :: elat = 0._r_kind      ! earth lat-lon for redistribution
     real(r_kind)    :: elon = 0._r_kind      ! earth lat-lon for redistribution

!     real(r_kind)    :: dlat = 0._r_kind      ! for verification, only temorary
!     real(r_kind)    :: dlon = 0._r_kind      ! for verification, only temorary

     integer(i_kind) :: idv  =-1              ! device ID
     integer(i_kind) :: iob  =-1              ! initial obs sequential ID

  contains

        !----------- overrideable procedures -----------------------------------
    procedure, nopass:: header_read  => obsHeader_read_         ! read a header
    procedure, nopass:: header_write => obsHeader_write_        ! write a header

    procedure:: init  => init_                                  ! initialize a node
    procedure:: clean => clean_                                 ! clean a node

        !----------- procedures must be defined by extensions ------------------
    procedure(intrfc_mytype_ ),nopass,deferred:: mytype     ! return my type name
    procedure(intrfc_setHop_ ), deferred:: setHop     ! re-construct H
    procedure(intrfc_xread_  ), deferred:: xread      ! read extensions
    procedure(intrfc_xwrite_ ), deferred:: xwrite     ! write extensions
    procedure(intrfc_isvalid_), deferred:: isvalid    ! validate extensions

    procedure(intrfc_gettlddp_), deferred:: gettlddp  ! (tlddp,nob)=(sum(%tld*%tld),sum(1)
        !--------- non_overrideable procedures are implemented statically ------
  end type obsNode

!-- module procedures, such as base-specific operations

        ! Nodes operations
  public:: obsNode_next         ! nextNode => obsNode_next (thisNode)
  public:: obsNode_append       ! call obsNode_append(thisNode,targetNode)

        interface obsNode_next  ; module procedure next_  ; end interface
        interface obsNode_append; module procedure append_; end interface

        ! Getters-and-setters
  public:: obsNode_islocal      ! is aNode local? -- obsNode_islocal(aNode)
  public:: obsNode_isluse       ! is aNode luse?  -- obsNode_isluse(aNode)
  public:: obsNode_setluse      ! set aNode%luse. -- call obsNode_setluse(aNode)

        interface obsNode_islocal; module procedure islocal_ ; end interface
        interface obsNode_isluse ; module procedure isluse_  ; end interface
        interface obsNode_setluse; module procedure setluse_ ; end interface

!-- module procedures, requiring base-specific operations

        ! reader-and-writer
  public:: obsNode_read         ! call obsNode_read(aNode, ...)
  public:: obsNode_write        ! call obsNode_write(aNode, ...)

        interface obsNode_read   ; module procedure read_   ; end interface
        interface obsNode_write  ; module procedure write_  ; end interface

  public:: obsNode_show         ! call obsNode_init(aNode)
        interface obsNode_show   ; module procedure show_   ; end interface

  abstract interface
    subroutine intrfc_xread_(aNode,iunit,istat,diagLookup,skip)
      use kinds,only: i_kind
      use obsmod, only: obs_diags
      import:: obsNode
      implicit none
      class(obsNode), intent(inout):: aNode
      integer(kind=i_kind), intent(in ):: iunit
      integer(kind=i_kind), intent(out):: istat
      type(obs_diags)     , intent(in ):: diagLookup
      logical,optional    , intent(in ):: skip
    end subroutine intrfc_xread_
  end interface

  abstract interface
    subroutine intrfc_xwrite_(aNode,junit,jstat)
      use kinds,only: i_kind
      import:: obsNode
      implicit none
      class(obsNode), intent(in):: aNode
      integer(kind=i_kind), intent(in ):: junit
      integer(kind=i_kind), intent(out):: jstat
    end subroutine intrfc_xwrite_
  end interface

  abstract interface
    function intrfc_isvalid_(aNode) result(isvalid_)
      import:: obsNode
      implicit none
      logical:: isvalid_
      class(obsNode), intent(in):: aNode
    end function intrfc_isvalid_
  end interface

  abstract interface
    subroutine intrfc_setHop_(aNode)
      use kinds, only: r_kind
      import:: obsNode
      implicit none
      class(obsNode), intent(inout):: aNode
    end subroutine intrfc_setHop_
  end interface

  abstract interface
    function intrfc_mytype_()
      import:: obsNode
      implicit none
      character(len=:),allocatable:: intrfc_mytype_
    end function intrfc_mytype_
  end interface

  abstract interface
    pure subroutine intrfc_gettlddp_(aNode,jiter,tlddp,nob)
      use kinds, only: i_kind,r_kind
      import:: obsNode
      implicit none
      class(obsNode),intent(in):: aNode
      integer(kind=i_kind),intent(in):: jiter
      real(kind=r_kind),intent(inout):: tlddp
      integer(kind=i_kind),optional,intent(inout):: nob
    end subroutine intrfc_gettlddp_
  end interface

!~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  character(len=*),parameter :: myname='m_obsNode'

!#define DEBUG_TRACE
#include "mytrace.H"
#include "myassert.H"

contains

function next_(aNode) result(here_)
!-- associate to thisNode%llpoint.
  implicit none
  class(obsNode),pointer:: here_
  class(obsNode),target,intent(in):: aNode
  here_ => aNode%llpoint
end function next_

subroutine append_(thisNode,targetNode,follow)
!-- append targetNode to thisNode%llpoint, or thisNode if .not.associated(thisNode)
  implicit none
  class(obsNode),pointer ,intent(inout):: thisNode
  class(obsNode),target  ,intent(in   ):: targetNode
  logical       ,optional,intent(in):: follow  ! Follow targetNode%llpoint to its last node.
                                               ! The default is to nullify(thisNode%llpoint)

  character(len=*),parameter:: myname_=myname//"::append_"
  logical:: follow_
_ENTRY_(myname_)
  follow_=.false.
  if(present(follow)) follow_=follow

  if(.not.associated(thisNode)) then
    thisNode => targetNode              ! as the first node

  else
    thisNode%llpoint => targetNode      ! as an additional node
    thisNode => thisNode%llpoint

  endif

  if(follow_) then
    ! Follow thisNode to thisNode%llpoint, till its end, as targetNode is a
    ! valid linked-list.  The risk is the possibility of some circular
    ! association, evenif both linked-lists, thisNode and targetNode are given
    ! clean.

    do while(associated(thisNode%llpoint))
      ASSERT(.not.associated(thisNode%llpoint,targetNode))
        ! This assertion tries to identify possible circular association between
        ! linked-list::thisNode and linked-list::targetNode.

      thisNode => thisNode%llpoint
    enddo

  else
    ! Nullify(thisNode%llpoint) to avoid any possibility of circular
    ! association.  Note this action WILL touch the input target argument
    ! (targetNode) indirectly.

    thisNode%llpoint => null()
  endif
_EXIT_(myname_)
return
end subroutine append_

function islocal_(aNode)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    islocal_
!   prgmmr:      J. Guo
!
! abstract: check if this node is for the local grid partition.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  use mpimod, only: myPE
  use m_cvgridLookup, only: cvgridLookup_islocal
  implicit none
  logical:: islocal_
  class(obsNode),intent(in):: aNode
  character(len=*),parameter:: myname_=MYNAME//'::islocal_'
_ENTRY_(myname_)
  islocal_=cvgridLookup_islocal(aNode%elat,aNode%elon,myPE)
_EXIT_(myname_)
return
end function islocal_

function isluse_(aNode)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    isluse_
!   prgmmr:      J. Guo
!
! abstract: check the %luse value of this node
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  implicit none
  logical:: isluse_
  class(obsNode),intent(in):: aNode
  character(len=*),parameter:: myname_=MYNAME//'::isluse_'
_ENTRY_(myname_)
  isluse_=aNode%luse
_EXIT_(myname_)
return
end function isluse_

subroutine setluse_(aNode)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    lsummary_
!   prgmmr:      J. Guo
!
! abstract: set %luse value for locally-owned node.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  use mpimod, only: myPE
  use m_cvgridLookup, only: cvgridLookup_isluse
  implicit none
  class(obsNode),intent(inout):: aNode
  character(len=*),parameter:: myname_=MYNAME//'::setluse_'
_ENTRY_(myname_)
  aNode%luse = cvgridLookup_isluse(aNode%elat, aNode%elon, myPE)
_EXIT_(myname_)
return
end subroutine setluse_

!===================================================================
! Routines below are default code to be used, if they are not override
! by the code invoked this include-file.
subroutine obsHeader_read_(iunit,mobs,jread,istat)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    obsHeader_read_
!   prgmmr:      J. Guo
!
! abstract: read the jtype-block header record.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  implicit none
  integer(i_kind),intent(in ):: iunit
  integer(i_kind),intent(out):: mobs
  integer(i_kind),intent(out):: jread
  integer(i_kind),intent(out):: istat
  
  character(len=*),parameter:: myname_=MYNAME//'::obsHeader_read_'
_ENTRY_(myname_)
  read(iunit,iostat=istat) mobs,jread
_EXIT_(myname_)
return
end subroutine obsHeader_read_

subroutine obsHeader_write_(junit,mobs,jwrite,jstat)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    obsHeader_write_
!   prgmmr:      J. Guo
!
! abstract: write the jtype-block header record.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  implicit none
  integer(i_kind),intent(in ):: junit
  integer(i_kind),intent(in ):: mobs
  integer(i_kind),intent(in ):: jwrite
  integer(i_kind),intent(out):: jstat
  
  character(len=*),parameter:: myname_=MYNAME//'::obsHeader_write_'
_ENTRY_(myname_)
  write(junit,iostat=jstat) mobs,jwrite
_EXIT_(myname_)
return
end subroutine obsHeader_write_

subroutine init_(aNode)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    init_
!   prgmmr:      J. Guo
!
! abstract: allocate a node.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  implicit none
  class(obsNode),intent(out):: aNode

  character(len=*),parameter:: myname_=MYNAME//'::init_'
_ENTRY_(myname_)
!_TRACEV_(myname_,'%mytype() =',aNode%mytype())
  aNode%llpoint => null()
  aNode%luse = .false.
  aNode%time = 0._r_kind
  aNode%elat = 0._r_kind
  aNode%elon = 0._r_kind
  aNode%idv  =-1
  aNode%iob  =-1
_EXIT_(myname_)
return
end subroutine init_

subroutine clean_(aNode)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    clean_
!   prgmmr:      J. Guo
!
! abstract: clean a node
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  implicit none
  class(obsNode),intent(inout):: aNode

  character(len=*),parameter:: myname_=MYNAME//'::clean_'
_ENTRY_(myname_)
!_TRACEV_(myname_,'%mytype() =',aNode%mytype())
  call init_(aNode)
_EXIT_(myname_)
return
end subroutine clean_

subroutine read_(aNode,iunit,istat,redistr,diagLookup)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    read_
!   prgmmr:      J. Guo
!
! abstract: read the input for a node.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  use m_obsdiagNode, only: obsdiagLookup_locate
  use obsmod, only: obs_diag
  use obsmod, only: obs_diags
  implicit none
  class(obsNode),intent(inout):: aNode
  integer(i_kind),intent(in   ):: iunit
  integer(i_kind),intent(  out):: istat
  logical        ,intent(in   ):: redistr
  type(obs_diags),intent(in   ):: diagLookup

  character(len=*),parameter:: myname_=MYNAME//'::read_'
  integer(i_kind):: ier
_ENTRY_(myname_)

  istat=0
  read(iunit,iostat=ier) aNode%luse,aNode%time,aNode%elat,aNode%elon, &
                         !aNode%dlat,aNode%dlon, &
                         aNode%idv ,aNode%iob
        if(ier/=0) then
          call perr(myname_,'read(%(luse,time,elat,elon,...)), iostat =',ier)
          istat=-1
          _EXIT_(myname_)
          return
        endif

  istat=1               ! Now a complete xread(aNode) is expected.
  if(redistr) then      ! Or additional conditions must be considered.
    istat=0             ! A complete xread(aNode) is not expected, unless
    if(aNode%luse) then ! ... .and. ...
      if(islocal_(aNode)) istat=1
    endif
  endif

  call aNode%xread(iunit,ier,diagLookup,skip=istat==0)
        if(ier/=0) then
          call perr(myname_,'aNode%xread(), iostat =',ier)
          call perr(myname_,'                 skip =',istat==0)
          call perr(myname_,'                istat =',istat)
          istat=-2
          _EXIT_(myname_)
          return
        endif

_EXIT_(myname_)
return
end subroutine read_

subroutine write_(aNode,junit,jstat)
  implicit none
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    write_
!   prgmmr:      J. Guo
!
! abstract: write a node for output.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  class(obsNode),intent(in):: aNode
  integer(i_kind),intent(in   ):: junit
  integer(i_kind),intent(  out):: jstat

  character(len=*),parameter:: myname_=MYNAME//'::write_'
_ENTRY_(myname_)

  jstat=0
  write(junit,iostat=jstat) aNode%luse,aNode%time,aNode%elat,aNode%elon, &
                            !aNode%dlat,aNode%dlon, &
                            aNode%idv,aNode%iob
                if(jstat/=0) then
                  call perr(myname_,'write(%(luse,elat,elon,...)), jstat =',jstat)
                  _EXIT_(myname_)
                  return
                endif

  call aNode%xwrite(junit,jstat)
                if (jstat/=0) then
                  call perr(myname_,'aNode%xwrite(), jstat =',jstat)
                  _EXIT_(myname_)
                  return
                end if
_EXIT_(myname_)
return
end subroutine write_

subroutine show_(aNode,iob)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    show_
!   prgmmr:      J. Guo
!
! abstract: show selected obsNode data.
!
! program history log:
!   2015-01-12  guo     - constructed for generic obsNode
!
!   input argument list: (see Fortran declarations below)
!
!   output argument list: (see Fortran declarations below)
!
! attributes:
!   language: f90/f95/f2003/f2008
!   machine:
!
!$$$ end documentation block
  use mpeu_util, only: stdout
  implicit none
  class(obsNode),intent(inout):: aNode
  integer(i_kind),intent(in   ):: iob

  character(len=*),parameter:: myname_=MYNAME//'::show_'
  logical:: isvalid_
_ENTRY_(myname_)
  isvalid_=aNode%isvalid()
  write(stdout,"(2a,3i4,2x,2l1,3f8.2)") myname,":: iob,%(idv,iob,luse,vald,time,elat,elon) =", &
        iob,aNode%idv,aNode%iob,aNode%luse,isvalid_,aNode%time,aNode%elat,aNode%elon
_EXIT_(myname_)
return
end subroutine show_

end module m_obsNode
