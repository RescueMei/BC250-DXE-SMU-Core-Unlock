#include <Uefi.h>

#include <Library/BaseLib.h>
#include <Library/DebugLib.h>
#include <Library/PciSegmentLib.h>
#include <Library/TimerLib.h>
#include <Library/UefiLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>

//
// This DXE driver mirrors the BC-250 Linux proof-of-concept by rw-r-r-0664 at https://github.com/rw-r-r-0644/bc250-core-unlock
//
// Operational flow:
//   1. Read SMN 0x0115A870 through the host bridge SMN index/data window.
//   2. If the low byte is 0xFF, the system is already unlocked -> exit.
//   3. Otherwise, use SMU Queue 3 message 0x98 to force that SMN location
//      to 0x00FF.
//   4. Verify the mask changed to 0xFF.
//   5. Issue a warm reset so the next boot enumerates all 8 cores.
//
//
#define BC250_HOST_PCI_SEGMENT      0
#define BC250_HOST_PCI_BUS          0
#define BC250_HOST_PCI_DEVICE       0
#define BC250_HOST_PCI_FUNCTION     0

// PCI configuration-space offsets used as the AMD SMN index/data window.
#define SMN_INDEX_OFFSET            0xB8
#define SMN_DATA_OFFSET             0xBC

// BC-250 core presence mask register and unlocked value.
#define MASK_REG                    0x0115A870U
#define UNLOCKED_MASK               0xFFU

// SMU Queue 3 command used by the Linux reference to force-write 0x00FF.
#define MSG_WRITE_FF                0x98U

// Queue 3 SMN mailbox registers.
#define Q3_CMD                      0x03B10A20U
#define Q3_RSP                      0x03B10A80U
#define Q3_ARG                      0x03B10A88U

// Polling parameters chosen to closely match the userspace reference.
#define MAILBOX_POLL_DELAY_US       2000U
#define MAILBOX_TIMEOUT_US          5000000U

#define BC250_PCI_SEGMENT_ADDRESS(Offset) \
  PCI_SEGMENT_LIB_ADDRESS (BC250_HOST_PCI_SEGMENT, BC250_HOST_PCI_BUS, BC250_HOST_PCI_DEVICE, BC250_HOST_PCI_FUNCTION, (Offset))

/**
  Determine whether an SMU Queue 3 response value means the queue is idle or the
  last command has completed.

  The Linux reference script treats 0x01, 0xFF, 0xFE, 0xFD, and 0xFC as terminal
  response states. This helper preserves that exact behavior so the DXE driver
  stays aligned with the proven userspace sequence.

  @param[in] Status  Raw SMU queue response register value.

  @retval TRUE   Status is one of the known terminal states.
  @retval FALSE  Status is still busy or otherwise non-terminal.
**/
STATIC
BOOLEAN
IsDoneStatus (
  IN UINT32  Status
  )
{
  return (BOOLEAN)(Status == 0x01U ||
                    Status == 0xFFU ||
                    Status == 0xFEU ||
                    Status == 0xFDU ||
                    Status == 0xFCU);
}

/**
  Read a 32-bit value from an SMN register through the host bridge PCI config
  index/data pair.

  @param[in] Register  SMN register address.

  @return 32-bit value read from the addressed SMN register.
**/
STATIC
UINT32
SmnRead32 (
  IN UINT32  Register
  )
{
  PciSegmentWrite32 (BC250_PCI_SEGMENT_ADDRESS (SMN_INDEX_OFFSET), Register);
  return PciSegmentRead32 (BC250_PCI_SEGMENT_ADDRESS (SMN_DATA_OFFSET));
}

/**
  Write a 32-bit value to an SMN register through the host bridge PCI config
  index/data pair.

  This helper is only used internally for the Queue 3 mailbox registers; the
  driver does not provide any generic or externally configurable SMN write path.

  @param[in] Register  SMN register address.
  @param[in] Value     32-bit value to write.
**/
STATIC
VOID
SmnWrite32 (
  IN UINT32  Register,
  IN UINT32  Value
  )
{
  PciSegmentWrite32 (BC250_PCI_SEGMENT_ADDRESS (SMN_INDEX_OFFSET), Register);
  PciSegmentWrite32 (BC250_PCI_SEGMENT_ADDRESS (SMN_DATA_OFFSET), Value);
}

/**
  Poll the Queue 3 response register until a terminal status appears or a timeout
  expires.

  The timeout logic is based on elapsed performance-counter time converted with
  GetTimeInNanoSecond(), rather than relying on fixed iteration counts.

  @param[out] Status     Last value observed in Q3_RSP.
  @param[in]  TimeoutUs  Maximum time to wait, in microseconds.

  @retval EFI_SUCCESS  A terminal Queue 3 status was observed.
  @retval EFI_TIMEOUT  The queue never reached a terminal state in time.
**/
STATIC
EFI_STATUS
WaitForDoneStatus (
  OUT UINT32  *Status,
  IN  UINT64  TimeoutUs
  )
{
  UINT64  Start;
  UINT64  ElapsedUs;
  UINT32  Value;

  Start = GetPerformanceCounter ();

  for (;;) {
    Value = SmnRead32 (Q3_RSP);
    if (IsDoneStatus (Value)) {
      *Status = Value;
      return EFI_SUCCESS;
    }

    ElapsedUs = DivU64x32 (GetTimeInNanoSecond (GetPerformanceCounter () - Start), 1000U);
    if (ElapsedUs >= TimeoutUs) {
      *Status = Value;
      return EFI_TIMEOUT;
    }

    MicroSecondDelay (MAILBOX_POLL_DELAY_US);
  }
}

/**
  Send a command through SMU Queue 3 using the mailbox order employed by the
  Linux Python reference implementation.

  Sequence:
    1. Wait for Queue 3 to reach a terminal state.
    2. Clear Q3_RSP.
    3. Write the first argument DWORD.
    4. Clear the second argument DWORD.
    5. Write the command opcode.
    6. Wait for completion.

  @param[in]  Message   Queue 3 message opcode.
  @param[in]  Argument  First 32-bit argument to the message.
  @param[out] Status    Terminal Q3_RSP value after the send completes or times out.

  @retval EFI_SUCCESS  The queue reached a terminal state both before and after send.
  @retval others       Queue readiness or completion timed out.
**/
STATIC
EFI_STATUS
SendQueue3Message (
  IN  UINT32  Message,
  IN  UINT32  Argument,
  OUT UINT32  *Status
  )
{
  EFI_STATUS  Result;

  Result = WaitForDoneStatus (Status, MAILBOX_TIMEOUT_US);
  if (EFI_ERROR (Result)) {
    DEBUG ((DEBUG_ERROR, "Bc250CoreUnlockDxe: SMU mailbox not idle, last status=0x%08x\n", *Status));
    return Result;
  }

  SmnWrite32 (Q3_RSP, 0);
  SmnWrite32 (Q3_ARG, Argument);
  SmnWrite32 (Q3_ARG + sizeof (UINT32), 0);
  SmnWrite32 (Q3_CMD, Message);

  Result = WaitForDoneStatus (Status, MAILBOX_TIMEOUT_US);
  if (EFI_ERROR (Result)) {
    DEBUG ((DEBUG_ERROR, "Bc250CoreUnlockDxe: SMU mailbox timed out after command 0x%08x\n", Message));
  }

  return Result;
}

/**
  DXE entry point.

  The driver acts as a one-shot policy gate based on the current core mask:

  * 0xFF -> already unlocked, continue normal boot.
  * any other value -> perform the SMU write, verify success, warm reset.

  @param[in] ImageHandle   Standard UEFI image handle.
  @param[in] SystemTable   Standard UEFI system table pointer.

  @retval EFI_SUCCESS       Driver completed its work or safely declined to act.
  @retval EFI_DEVICE_ERROR  Warm reset was requested but control unexpectedly returned.
**/
EFI_STATUS
EFIAPI
Bc250CoreUnlockEntryPoint (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;
  UINT32      MaskValue;
  UINT32      MailboxStatus;
  UINT8       MaskLowByte;

  DEBUG ((DEBUG_INFO, "Bc250CoreUnlockDxe: entry\n"));

  MaskValue = SmnRead32 (MASK_REG);
  MaskLowByte = (UINT8)(MaskValue & 0xFFU);

  DEBUG ((DEBUG_INFO, "Bc250CoreUnlockDxe: core presence mask=0x%08x\n", MaskValue));

  if (MaskLowByte == UNLOCKED_MASK) {
    DEBUG ((DEBUG_INFO, "Bc250CoreUnlockDxe: mask already 0xFF, continuing normal boot\n"));
    return EFI_SUCCESS;
  }

  MailboxStatus = 0;
  Status = SendQueue3Message (MSG_WRITE_FF, MASK_REG, &MailboxStatus);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "Bc250CoreUnlockDxe: failed to send SMU message 0x98: %r\n", Status));
    return EFI_SUCCESS;
  }

  if (MailboxStatus != 0x01U) {
    DEBUG ((DEBUG_ERROR, "Bc250CoreUnlockDxe: SMU message 0x98 returned 0x%08x, aborting reset\n", MailboxStatus));
    return EFI_SUCCESS;
  }

  MicroSecondDelay (50000U);

  MaskValue = SmnRead32 (MASK_REG);
  MaskLowByte = (UINT8)(MaskValue & 0xFFU);
  DEBUG ((DEBUG_INFO, "Bc250CoreUnlockDxe: post-write mask=0x%08x\n", MaskValue));

  if (MaskLowByte != UNLOCKED_MASK) {
    DEBUG ((DEBUG_ERROR, "Bc250CoreUnlockDxe: mask verification failed, skipping reset\n"));
    return EFI_SUCCESS;
  }

  DEBUG ((DEBUG_INFO, "Bc250CoreUnlockDxe: unlock succeeded, issuing warm reset\n"));
  gRT->ResetSystem (EfiResetWarm, EFI_SUCCESS, 0, NULL);

  return EFI_DEVICE_ERROR;
}
