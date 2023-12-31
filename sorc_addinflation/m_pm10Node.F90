module m_pm10Node
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:	 module m_pm10Node
!   prgmmr:	 j guo <jguo@nasa.gov>
!      org:	 NASA/GSFC, Global Modeling and Assimilation Office, 610.3
!     date:	 2016-05-18
!
! abstract: class-module of obs-type pm10Node (in-situ pm-10)
!
! program history log:
!   2016-05-18  j guo   - added this document block for the initial polymorphic
!                         implementation.
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
  use obsmod, only: obs_diag
  use obsmod, only: obs_diags
  use kinds , only: i_kind,r_kind
  use mpeu_util, only: assert_,die,perr,warn,tell
  use m_obsNode, only: obsNode
  implicit none
  private

  public:: pm10Node

  type,extends(obsNode):: pm10Node
! to avoid separate coding for pm10 profile e.g. from aircraft or 
! soundings obs weights are coded as 
! wij(8) even though for surface pm10 wij(4) would be sufficient.
! also surface pm10 may be treated differently than now for vertical
! interpolation

     !type(pm10_ob_type),pointer :: llpoint => NULL()
     type(obs_diag), pointer :: diags => NULL()
     real(r_kind)    :: res           !  pm10 residual
     real(r_kind)    :: err2          !  pm10 obs error squared
     real(r_kind)    :: raterr2       !  square of ratio of final obs error
!  to original obs error
     !real(r_kind)    :: time          !  observation time
     real(r_kind)    :: b             !  variational quality control parameter
     real(r_kind)    :: pg            !  variational quality control parameter
     real(r_kind)    :: wij(8)        !  horizontal interpolation weights
     integer(i_kind) :: ij(8)         !  horizontal locations
     !logical         :: luse          !  flag indicating if ob is used in pen.
     !integer(i_kind) :: idv,iob       ! device id and obs index for sorting
     !real   (r_kind) :: elat, elon      ! earth lat-lon for redistribution
     !real   (r_kind) :: dlat, dlon      ! earth lat-lon for redistribution
     real   (r_kind) :: dlev            ! reference to the vertical grid
  contains
    procedure,nopass::  mytype
    procedure::  setHop => obsNode_setHop_
    procedure::   xread => obsNode_xread_
    procedure::  xwrite => obsNode_xwrite_
    procedure:: isvalid => obsNode_isvalid_
    procedure::  gettlddp => gettlddp_

    ! procedure, nopass:: headerRead  => obsHeader_read_
    ! procedure, nopass:: headerWrite => obsHeader_write_
    ! procedure:: init  => obsNode_init_
    ! procedure:: clean => obsNode_clean_
  end type pm10Node
  
  public:: pm10Node_typecast
  public:: pm10Node_nextcast
        interface pm10Node_typecast; module procedure typecast_ ; end interface
        interface pm10Node_nextcast; module procedure nextcast_ ; end interface

  character(len=*),parameter:: MYNAME="m_pm10Node"

!#define CHECKSUM_VERBOSE
!#define DEBUG_TRACE
#include "myassert.H"
#include "mytrace.H"
contains
function typecast_(aNode) result(ptr_)
!-- cast a class(obsNode) to a type(pm10Node)
  use m_obsNode, only: obsNode
  implicit none
  type(pm10Node),pointer:: ptr_
  class(obsNode),pointer,intent(in):: aNode
  character(len=*),parameter:: myname_=MYNAME//"::typecast_"
  ptr_ => null()
  if(.not.associated(aNode)) return
  select type(aNode)
  type is(pm10Node)
    ptr_ => aNode
  class default
    call die(myname_,'unexpected type, aNode%mytype() =',aNode%mytype())
  end select
return
end function typecast_

function nextcast_(aNode) result(ptr_)
!-- cast an obsNode_next(obsNode) to a type(pm10Node)
  use m_obsNode, only: obsNode,obsNode_next
  implicit none
  type(pm10Node),pointer:: ptr_
  class(obsNode),target,intent(in):: aNode

  class(obsNode),pointer:: anode_
  anode_ => obsNode_next(aNode)
  ptr_ => typecast_(anode_)
return
end function nextcast_

! obsNode implementations

function mytype()
  implicit none
  character(len=:),allocatable:: mytype
  mytype="[pm10Node]"
end function mytype

subroutine obsNode_xread_(aNode,iunit,istat,diagLookup,skip)
  use m_obsdiagNode, only: obsdiagLookup_locate
  implicit none
  class(pm10Node) , intent(inout):: aNode
  integer(i_kind) , intent(in   ):: iunit
  integer(i_kind) , intent(  out):: istat
  type(obs_diags) , intent(in   ):: diagLookup
  logical,optional, intent(in   ):: skip

  character(len=*),parameter:: myname_=MYNAME//'.obsNode_xread_'
  logical:: skip_
  skip_=.false.
  if(present(skip)) skip_=skip

  istat=0
  if(skip_) then
    read(iunit,iostat=istat)
                if(istat/=0) then
                  call perr(myname_,'skipping read(%(res,err2,...)), iostat =',istat)
                  _EXIT_(myname_)
                  return
                endif

  else
    read(iunit,iostat=istat)    aNode%res    , &
                                aNode%err2   , &
                                aNode%raterr2, &
                                aNode%b      , &
                                aNode%pg     , &
                                aNode%dlev   , &
                                aNode%wij    , &
                                aNode%ij
                if (istat/=0) then
                  call perr(myname_,'read(%(res,err2,...)), iostat =',istat)
                  _EXIT_(myname_)
                  return
                end if

    aNode%diags => obsdiagLookup_locate(diagLookup,aNode%idv,aNode%iob,1_i_kind)
                if(.not.associated(aNode%diags)) then
                  call perr(myname_,'obsdiagLookup_locate(), %idv =',aNode%idv)
                  call perr(myname_,'                        %iob =',aNode%iob)
                  call  die(myname_)
                endif
  endif
_EXIT_(myname_)
return
end subroutine obsNode_xread_

subroutine obsNode_xwrite_(aNode,junit,jstat)
  implicit none
  class(pm10Node),intent(in):: aNode
  integer(i_kind),intent(in   ):: junit
  integer(i_kind),intent(  out):: jstat

  character(len=*),parameter:: myname_=MYNAME//'.obsNode_xwrite_'

  jstat=0
  write(junit,iostat=jstat)     aNode%res    , &
                                aNode%err2   , &
                                aNode%raterr2, &
                                aNode%b      , &
                                aNode%pg     , &
                                aNode%dlev   , &
                                aNode%wij    , &
                                aNode%ij
                if (jstat/=0) then
                  call perr(myname_,'write(%(res,err2,...)), iostat =',jstat)
                  _EXIT_(myname_)
                  return
                end if
_EXIT_(myname_)
return
end subroutine obsNode_xwrite_

subroutine obsNode_setHop_(aNode)
  use m_cvgridLookup, only: cvgridLookup_getiw
  implicit none
  class(pm10Node),intent(inout):: aNode

!  character(len=*),parameter:: myname_=MYNAME//'.obsNode_setHop_'
!_ENTRY_(myname_)
  ! %dlev is defined, but not used.  See setuppm10() for information.
  call cvgridLookup_getiw(aNode%elat,aNode%elon,aNode%ij(1:4),aNode%wij(1:4))
  aNode% ij(5:8) = aNode%ij(1:4)
  aNode%wij(5:8) = 0._r_kind
!_EXIT_(myname_)
return
end subroutine obsNode_setHop_

function obsNode_isvalid_(aNode) result(isvalid_)
  implicit none
  logical:: isvalid_
  class(pm10Node),intent(in):: aNode

!  character(len=*),parameter:: myname_=MYNAME//'::obsNode_isvalid_'
!_ENTRY_(myname_)
  isvalid_=associated(aNode%diags)
!_EXIT_(myname_)
return
end function obsNode_isvalid_

pure subroutine gettlddp_(aNode,jiter,tlddp,nob)
  use kinds, only: r_kind
  implicit none
  class(pm10Node), intent(in):: aNode
  integer(kind=i_kind),intent(in):: jiter
  real(kind=r_kind),intent(inout):: tlddp
  integer(kind=i_kind),optional,intent(inout):: nob

  tlddp = tlddp + aNode%diags%tldepart(jiter)*aNode%diags%tldepart(jiter)
  if(present(nob)) nob=nob+1
return
end subroutine gettlddp_

end module m_pm10Node
