/*++

Copyright (c) Microsoft Corporation

Abstract:

    This module contains a sample implementation of an indirect display driver. See the included README.md file and the
    various TODO blocks throughout this file and all accompanying files for information on building a production driver.

    MSDN documentation on indirect displays can be found at https://msdn.microsoft.com/en-us/library/windows/hardware/mt761968(v=vs.85).aspx.

Environment:

    User Mode, UMDF

    For tracing log, use Inflight Trace Record (IFR) https://docs.microsoft.com/en-us/windows-hardware/drivers/wdf/using-wpp-software-tracing-in-kmdf-and-umdf-2-drivers
    // https://docs.microsoft.com/en-us/windows-hardware/drivers/devtest/adding-wpp-software-tracing-to-a-windows-driver#step-5-instrument-the-driver-code-to-generate-trace-messages-at-appropriate-points
--*/

#include <tchar.h>

#include "Driver.h"
#include "Driver.tmh"
#include "Public.h"

//
// Define an Interface Guid for NikoDeskIddDriver device class.
// This GUID is used to register (IoRegisterDeviceInterface)
// an instance of an interface so that user application
// can control the NikoDeskIddDriver device.
//
const GUID GUID_DEVINTERFACE_IDD_DRIVER_DEVICE =
    {0x52d81e52, 0x2aba, 0x4c3b, {0x9d, 0x2d, 0xa2, 0x71, 0x93, 0xf3, 0x29, 0x4f}};


using namespace std;
using namespace Microsoft::IndirectDisp;
using namespace Microsoft::WRL;

// Fixed SDR modes, with no borrowed vendor EDID or global configuration.
static const IndirectSampleMonitor::SampleMonitorMode s_SampleDefaultModes[] = {
    {1920, 1080, 60}, {2560, 1440, 60}, {3840, 2160, 60},
};


#pragma region helpers

static inline void FillSignalInfo(DISPLAYCONFIG_VIDEO_SIGNAL_INFO& Mode, DWORD Width, DWORD Height, DWORD VSync, bool bMonitorMode)
{
    Mode.totalSize.cx = Mode.activeSize.cx = Width;
    Mode.totalSize.cy = Mode.activeSize.cy = Height;

    // See https://docs.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_video_signal_info
    Mode.AdditionalSignalInfo.vSyncFreqDivider = bMonitorMode ? 0 : 1;
    Mode.AdditionalSignalInfo.videoStandard = 255;

    Mode.vSyncFreq.Numerator = VSync;
    Mode.vSyncFreq.Denominator = 1;
    Mode.hSyncFreq.Numerator = VSync * Height;
    Mode.hSyncFreq.Denominator = 1;

    Mode.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;

    Mode.pixelRate = ((UINT64) VSync) * ((UINT64) Width) * ((UINT64) Height);
}

static IDDCX_MONITOR_MODE CreateIddCxMonitorMode(DWORD Width, DWORD Height, DWORD VSync, IDDCX_MONITOR_MODE_ORIGIN Origin = IDDCX_MONITOR_MODE_ORIGIN_DRIVER)
{
    IDDCX_MONITOR_MODE Mode = {};

    Mode.Size = sizeof(Mode);
    Mode.Origin = Origin;
    FillSignalInfo(Mode.MonitorVideoSignalInfo, Width, Height, VSync, true);

    return Mode;
}

static IDDCX_TARGET_MODE CreateIddCxTargetMode(DWORD Width, DWORD Height, DWORD VSync)
{
    IDDCX_TARGET_MODE Mode = {};

    Mode.Size = sizeof(Mode);
    FillSignalInfo(Mode.TargetVideoSignalInfo.targetVideoSignalInfo, Width, Height, VSync, false);

    return Mode;
}

#pragma endregion

extern "C" DRIVER_INITIALIZE DriverEntry;

EVT_WDF_DRIVER_UNLOAD NikoDeskIddDriverUnload;
EVT_WDF_DRIVER_DEVICE_ADD IddNikoDeskDeviceAdd;
EVT_WDF_DEVICE_D0_ENTRY IddNikoDeskDeviceD0Entry;

// https://docs.microsoft.com/en-us/windows-hardware/drivers/kernel/defining-i-o-control-codes
EVT_IDD_CX_DEVICE_IO_CONTROL IddNikoDeskIoDeviceControl;

EVT_IDD_CX_ADAPTER_INIT_FINISHED IddNikoDeskAdapterInitFinished;
EVT_IDD_CX_ADAPTER_COMMIT_MODES IddNikoDeskAdapterCommitModes;

EVT_IDD_CX_PARSE_MONITOR_DESCRIPTION IddNikoDeskParseMonitorDescription;
EVT_IDD_CX_MONITOR_GET_DEFAULT_DESCRIPTION_MODES IddNikoDeskMonitorGetDefaultModes;
EVT_IDD_CX_MONITOR_QUERY_TARGET_MODES IddNikoDeskMonitorQueryModes;

EVT_IDD_CX_MONITOR_ASSIGN_SWAPCHAIN IddNikoDeskMonitorAssignSwapChain;
EVT_IDD_CX_MONITOR_UNASSIGN_SWAPCHAIN IddNikoDeskMonitorUnassignSwapChain;

struct IndirectDeviceContextWrapper
{
    IndirectDeviceContext* pContext;

    void Cleanup()
    {
        delete pContext;
        pContext = nullptr;
    }
};

struct IndirectMonitorContextWrapper
{
    IndirectMonitorContext* pContext;

    void Cleanup()
    {
        delete pContext;
        pContext = nullptr;
    }
};

// This macro creates the methods for accessing an IndirectDeviceContextWrapper as a context for a WDF object
WDF_DECLARE_CONTEXT_TYPE(IndirectDeviceContextWrapper);

WDF_DECLARE_CONTEXT_TYPE(IndirectMonitorContextWrapper);

extern "C" BOOL WINAPI DllMain(
    _In_ HINSTANCE hInstance,
    _In_ UINT dwReason,
    _In_opt_ LPVOID lpReserved)
{
    UNREFERENCED_PARAMETER(hInstance);
    UNREFERENCED_PARAMETER(lpReserved);
    UNREFERENCED_PARAMETER(dwReason);

    return TRUE;
}

_Use_decl_annotations_
extern "C" NTSTATUS DriverEntry(
    PDRIVER_OBJECT  pDriverObject,
    PUNICODE_STRING pRegistryPath
)
{
    WDF_DRIVER_CONFIG Config;
    NTSTATUS Status;

    WDF_OBJECT_ATTRIBUTES Attributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&Attributes);

    WPP_INIT_TRACING(pDriverObject, pRegistryPath);

    WDF_DRIVER_CONFIG_INIT(&Config,
        IddNikoDeskDeviceAdd
    );
    Config.EvtDriverUnload = NikoDeskIddDriverUnload;

    // The WdfDriverCreate method creates a framework driver object for the calling driver.
    Status = WdfDriverCreate(pDriverObject, pRegistryPath, &Attributes, &Config, WDF_NO_HANDLE);
    if (!NT_SUCCESS(Status))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DRIVER,
            "%!FUNC! cannot create device %!STATUS!",
            Status);
        WPP_CLEANUP(pDriverObject);
    }
    else
    {
        TraceEvents(TRACE_LEVEL_INFORMATION,
            TRACE_DRIVER,
            "%!FUNC! driver created with path %wZ",
            pRegistryPath);
    }

    return Status;
}

_Use_decl_annotations_
void NikoDeskIddDriverUnload(_In_ WDFDRIVER Driver)
{
    WPP_CLEANUP(WdfDriverWdmGetDriverObject(Driver));
}

// https://community.osr.com/discussion/290895/how-to-realize-hot-plug-function-of-virtual-display-with-indirect-display
// Hi,
// in Indirect display driver, after use WdfDeviceCreateDeviceInterface to create guid, 
// you should use IddCxDeviceInitialize, IddDeviceIoControl is not the same as other wdf's DeviceIoControl function,
// his first argument is WDFDEVICE Device,not WDFQUEUE,
// so you don't need to use WdfIoQueueCreate to create a queue to receive I / O queue message.
// After all of the above, you should create IOCTL code, this can establish communication between applicationand idd device.
_Use_decl_annotations_
NTSTATUS IddNikoDeskDeviceAdd(WDFDRIVER Driver, PWDFDEVICE_INIT pDeviceInit)
{
    NTSTATUS Status = STATUS_SUCCESS;
    WDF_PNPPOWER_EVENT_CALLBACKS PnpPowerCallbacks;

    UNREFERENCED_PARAMETER(Driver);

    // Register for power callbacks - in this sample only power-on is needed
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&PnpPowerCallbacks);
    PnpPowerCallbacks.EvtDeviceD0Entry = IddNikoDeskDeviceD0Entry;
    WdfDeviceInitSetPnpPowerEventCallbacks(pDeviceInit, &PnpPowerCallbacks);

    IDD_CX_CLIENT_CONFIG IddConfig;
    IDD_CX_CLIENT_CONFIG_INIT(&IddConfig);

    // If the driver wishes to handle custom IoDeviceControl requests, it's necessary to use this callback since IddCx
    // redirects IoDeviceControl requests to an internal queue. This sample does not need this.
    // https://docs.microsoft.com/zh-cn/windows-hardware/drivers/display/iddcx-objects
    IddConfig.EvtIddCxDeviceIoControl = IddNikoDeskIoDeviceControl;

    IddConfig.EvtIddCxAdapterInitFinished = IddNikoDeskAdapterInitFinished;

    IddConfig.EvtIddCxParseMonitorDescription = IddNikoDeskParseMonitorDescription;
    IddConfig.EvtIddCxMonitorGetDefaultDescriptionModes = IddNikoDeskMonitorGetDefaultModes;
    IddConfig.EvtIddCxMonitorQueryTargetModes = IddNikoDeskMonitorQueryModes;
    IddConfig.EvtIddCxAdapterCommitModes = IddNikoDeskAdapterCommitModes;
    IddConfig.EvtIddCxMonitorAssignSwapChain = IddNikoDeskMonitorAssignSwapChain;
    IddConfig.EvtIddCxMonitorUnassignSwapChain = IddNikoDeskMonitorUnassignSwapChain;

    Status = IddCxDeviceInitConfig(pDeviceInit, &IddConfig);
    if (!NT_SUCCESS(Status))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DRIVER,
            "%!FUNC! cannot init device config %!STATUS!",
            Status);
        return Status;
    }

    WDF_OBJECT_ATTRIBUTES Attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&Attr, IndirectDeviceContextWrapper);
    Attr.EvtCleanupCallback = [](WDFOBJECT Object)
    {
        // Automatically cleanup the context when the WDF object is about to be deleted
        auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(Object);
        if (pContext)
        {
            pContext->Cleanup();
        }
    };

    WDFDEVICE Device = nullptr;
    Status = WdfDeviceCreate(&pDeviceInit, &Attr, &Device);
    if (!NT_SUCCESS(Status))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DEVICE,
            "%!FUNC! cannot create device %!STATUS!",
            Status);
        return Status;
    }

    //
    // Create device interface for this device. The interface will be
    // enabled by the framework when we return from StartDevice successfully.
    // Clients of this driver will open this interface and send ioctls.
    //
    Status = WdfDeviceCreateDeviceInterface(
        Device,
        &GUID_DEVINTERFACE_IDD_DRIVER_DEVICE,
        NULL // No Reference String. If you provide one it will appended to the
    );   // symbolic link. Some drivers register multiple interfaces for the same device
         // and use the reference string to distinguish between them
    if (!NT_SUCCESS(Status))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DEVICE,
            "%!FUNC! WdfDeviceCreateDeviceInterface failed %!STATUS!",
            Status);
        return Status;
    }

    Status = IddCxDeviceInitialize(Device);
    if (!NT_SUCCESS(Status))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DEVICE,
            "%!FUNC! cannot initialize device %!STATUS!",
            Status);
        return Status;
    }

    // Create a new device context object and attach it to the WDF device object
    auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(Device);
    pContext->pContext = new (std::nothrow) IndirectDeviceContext(Device);
    if (!pContext->pContext) return STATUS_INSUFFICIENT_RESOURCES;

    return Status;
}

_Use_decl_annotations_
NTSTATUS IddNikoDeskDeviceD0Entry(WDFDEVICE Device, WDF_POWER_DEVICE_STATE PreviousState)
{
    UNREFERENCED_PARAMETER(PreviousState);

    // This function is called by WDF to start the device in the fully-on power state.

    auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(Device);
    pContext->pContext->InitAdapter();

    return STATUS_SUCCESS;
}

#pragma region Direct3DDevice

Direct3DDevice::Direct3DDevice(LUID AdapterLuid) : AdapterLuid(AdapterLuid)
{

}

Direct3DDevice::Direct3DDevice()
{
    AdapterLuid = LUID{};
}

HRESULT Direct3DDevice::Init()
{
    // The DXGI factory could be cached, but if a new render adapter appears on the system, a new factory needs to be
    // created. If caching is desired, check DxgiFactory->IsCurrent() each time and recreate the factory if !IsCurrent.
    HRESULT hr = CreateDXGIFactory2(0, IID_PPV_ARGS(&DxgiFactory));
    if (FAILED(hr))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DRIVER,
            "%!FUNC! cannot create dxgi factory2 %!HRESULT!",
            hr);
        return hr;
    }

    // Find the specified render adapter
    hr = DxgiFactory->EnumAdapterByLuid(AdapterLuid, IID_PPV_ARGS(&Adapter));
    if (FAILED(hr))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DRIVER,
            "%!FUNC! cannot enum adapter by luid %!HRESULT!",
            hr);
        return hr;
    }

    // Create a D3D device using the render adapter. BGRA support is required by the WHQL test suite.
    hr = D3D11CreateDevice(
        Adapter.Get(),
        D3D_DRIVER_TYPE_UNKNOWN,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr,
        0,
        D3D11_SDK_VERSION,
        &Device,
        nullptr,
        &DeviceContext);
    if (FAILED(hr))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DRIVER,
            "%!FUNC! cannot create d3d11 device %!HRESULT!",
            hr);

        // If creating the D3D device failed, it's possible the render GPU was lost (e.g. detachable GPU) or else the
        // system is in a transient state.
        return hr;
    }

    return S_OK;
}

#pragma endregion

#pragma region SwapChainProcessor

SwapChainProcessor::SwapChainProcessor(IDDCX_SWAPCHAIN hSwapChain, shared_ptr<Direct3DDevice> Device, HANDLE NewFrameEvent)
    : m_hSwapChain(hSwapChain), m_Device(Device), m_hAvailableBufferEvent(NewFrameEvent)
{
    m_hTerminateEvent.Attach(CreateEvent(nullptr, FALSE, FALSE, nullptr));
    if (!m_hTerminateEvent.Get()) {
        WdfObjectDelete(m_hSwapChain); m_hSwapChain = nullptr; return;
    }

    // Immediately create and run the swap-chain processing thread, passing 'this' as the thread parameter
    m_hThread.Attach(CreateThread(nullptr, 0, RunThread, this, 0, nullptr));
    if (!m_hThread.Get()) { WdfObjectDelete(m_hSwapChain); m_hSwapChain = nullptr; }
}

SwapChainProcessor::~SwapChainProcessor()
{
    // Alert the swap-chain processing thread to terminate
    SetEvent(m_hTerminateEvent.Get());

    if (m_hThread.Get())
    {
        // Wait for the thread to terminate
        WaitForSingleObject(m_hThread.Get(), INFINITE);
    }
}

DWORD CALLBACK SwapChainProcessor::RunThread(LPVOID Argument)
{
    reinterpret_cast<SwapChainProcessor*>(Argument)->Run();
    return 0;
}

void SwapChainProcessor::Run()
{
    // For improved performance, make use of the Multimedia Class Scheduler Service, which will intelligently
    // prioritize this thread for improved throughput in high CPU-load scenarios.
    DWORD AvTask = 0;
    HANDLE AvTaskHandle = AvSetMmThreadCharacteristics(_T("Distribution"), &AvTask);

    RunCore();

    // Always delete the swap-chain object when swap-chain processing loop terminates in order to kick the system to
    // provide a new swap-chain if necessary.
    WdfObjectDelete((WDFOBJECT)m_hSwapChain);
    m_hSwapChain = nullptr;

    if (AvTaskHandle) AvRevertMmThreadCharacteristics(AvTaskHandle);
}

void SwapChainProcessor::RunCore()
{
    // Get the DXGI device interface
    ComPtr<IDXGIDevice> DxgiDevice;
    HRESULT hr = m_Device->Device.As(&DxgiDevice);
    if (FAILED(hr))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DRIVER,
            "%!FUNC! cannot convert dxgi device %!HRESULT!",
            hr);
        return;
    }

    IDARG_IN_SWAPCHAINSETDEVICE SetDevice = {};
    SetDevice.pDevice = DxgiDevice.Get();

    hr = IddCxSwapChainSetDevice(m_hSwapChain, &SetDevice);
    if (FAILED(hr))
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DRIVER,
            "%!FUNC! failed, swap chain set device %!HRESULT!",
            hr);
        return;
    }

    TraceEvents(TRACE_LEVEL_RESERVED7, TRACE_DRIVER, "%!FUNC! begin acquire and release buffers in a loop");

    // Acquire and release buffers in a loop
    for (;;)
    {
        // A continuously ready producer must not starve disconnect/monitor teardown.
        if (WaitForSingleObject(m_hTerminateEvent.Get(), 0) == WAIT_OBJECT_0) break;
        ComPtr<IDXGIResource> AcquiredBuffer;

        // Ask for the next buffer from the producer
        IDARG_OUT_RELEASEANDACQUIREBUFFER Buffer = {};
        hr = IddCxSwapChainReleaseAndAcquireBuffer(m_hSwapChain, &Buffer);

        // AcquireBuffer immediately returns STATUS_PENDING if no buffer is yet available
        if (hr == E_PENDING)
        {
            // We must wait for a new buffer
            HANDLE WaitHandles [] =
            {
                m_hAvailableBufferEvent,
                m_hTerminateEvent.Get()
            };
            DWORD WaitResult = WaitForMultipleObjects(ARRAYSIZE(WaitHandles), WaitHandles, FALSE, 16);
            if (WaitResult == WAIT_OBJECT_0 || WaitResult == WAIT_TIMEOUT)
            {
                // We have a new buffer, so try the AcquireBuffer again
                continue;
            }
            else if (WaitResult == WAIT_OBJECT_0 + 1)
            {
                // We need to terminate
                TraceEvents(TRACE_LEVEL_RESERVED7,
                    TRACE_DRIVER,
                    "%!FUNC! Terminate");
                break;
            }
            else
            {
                // The wait was cancelled or something unexpected happened
                hr = HRESULT_FROM_WIN32(WaitResult);

                TraceEvents(TRACE_LEVEL_RESERVED6,
                    TRACE_DRIVER,
                    "%!FUNC! The wait was cancelled or something unexpected happened %!HRESULT!",
                    hr);
                break;
            }
        }
        else if (SUCCEEDED(hr))
        {
            // We have new frame to process, the surface has a reference on it that the driver has to release
            AcquiredBuffer.Attach(Buffer.MetaData.pSurface);

            // ==============================
            // TODO: Process the frame here
            //
            // This is the most performance-critical section of code in an IddCx driver. It's important that whatever
            // is done with the acquired surface be finished as quickly as possible. This operation could be:
            //  * a GPU copy to another buffer surface for later processing (such as a staging surface for mapping to CPU memory)
            //  * a GPU encode operation
            //  * a GPU VPBlt to another surface
            //  * a GPU custom compute shader encode operation
            // ==============================

            // We have finished processing this frame hence we release the reference on it.
            // If the driver forgets to release the reference to the surface, it will be leaked which results in the
            // surfaces being left around after swapchain is destroyed.
            // NOTE: Although in this sample we release reference to the surface here; the driver still
            // owns the Buffer.MetaData.pSurface surface until IddCxSwapChainReleaseAndAcquireBuffer returns
            // S_OK and gives us a new frame, a driver may want to use the surface in future to re-encode the desktop 
            // for better quality if there is no new frame for a while
            AcquiredBuffer.Reset();
            
            // Indicate to OS that we have finished inital processing of the frame, it is a hint that
            // OS could start preparing another frame
            hr = IddCxSwapChainFinishedProcessingFrame(m_hSwapChain);
            if (FAILED(hr))
            {
                TraceEvents(TRACE_LEVEL_ERROR,
                    TRACE_DRIVER,
                    "%!FUNC! cannot finish processing frame %!HRESULT!",
                    hr);
                break;
            }

            // ==============================
            // TODO: Report frame statistics once the asynchronous encode/send work is completed
            //
            // Drivers should report information about sub-frame timings, like encode time, send time, etc.
            // ==============================
            // IddCxSwapChainReportFrameStatistics(m_hSwapChain, ...);
        }
        else
        {
            // The swap-chain was likely abandoned (e.g. DXGI_ERROR_ACCESS_LOST), so exit the processing loop
            TraceEvents(TRACE_LEVEL_ERROR,
                TRACE_DRIVER,
                "%!FUNC! The swap-chain was likely abandoned %!HRESULT!",
                hr);
            break;
        }
    }
}

#pragma endregion

#pragma region IndirectDeviceContext

IndirectDeviceContext::IndirectDeviceContext(_In_ WDFDEVICE WdfDevice)
    : m_AdapterInitStatus(STATUS_DEVICE_NOT_READY)
    , m_WdfDevice(WdfDevice)
{
    m_Adapter = {};

    for (UINT i = 0; i < m_sMaxMonitorCount; i++)
    {
        m_Monitors[i] = NULL;
    }
}

IndirectDeviceContext::~IndirectDeviceContext()
{
    // The WDF parent owns child monitor/swapchain teardown. No other adapter is touched.
}

void IndirectDeviceContext::InitAdapter()
{
    // ==============================
    // TODO: Update the below diagnostic information in accordance with the target hardware. The strings and version
    // numbers are used for telemetry and may be displayed to the user in some situations.
    //
    // This is also where static per-adapter capabilities are determined.
    // ==============================

    std::lock_guard<std::mutex> lock(m_Lock);
    if (m_Adapter) return; // Resume reuses this instance; it never creates a second adapter.
    IDDCX_ADAPTER_CAPS AdapterCaps = {};
    AdapterCaps.Size = sizeof(AdapterCaps);

    // Declare basic feature support for the adapter (required)
    AdapterCaps.MaxMonitorsSupported = Microsoft::IndirectDisp::IndirectDeviceContext::GetMaxMonitorCount();
    AdapterCaps.EndPointDiagnostics.Size = sizeof(AdapterCaps.EndPointDiagnostics);
    AdapterCaps.EndPointDiagnostics.GammaSupport = IDDCX_FEATURE_IMPLEMENTATION_NONE;
    AdapterCaps.EndPointDiagnostics.TransmissionType = IDDCX_TRANSMISSION_TYPE_WIRED_OTHER;

    // Declare your device strings for telemetry (required)
    AdapterCaps.EndPointDiagnostics.pEndPointFriendlyName = L"NikoDesk Idd Device";
    AdapterCaps.EndPointDiagnostics.pEndPointManufacturerName = L"NikoDesk";
    AdapterCaps.EndPointDiagnostics.pEndPointModelName = L"NikoDesk Idd Model";

    // Declare your hardware and firmware versions (required)
    IDDCX_ENDPOINT_VERSION Version = {};
    Version.Size = sizeof(Version);
    Version.MajorVer = 1;
    AdapterCaps.EndPointDiagnostics.pFirmwareVersion = &Version;
    AdapterCaps.EndPointDiagnostics.pHardwareVersion = &Version;

    // Initialize a WDF context that can store a pointer to the device context object
    WDF_OBJECT_ATTRIBUTES Attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&Attr, IndirectDeviceContextWrapper);

    IDARG_IN_ADAPTER_INIT AdapterInit = {};
    AdapterInit.WdfDevice = m_WdfDevice;
    AdapterInit.pCaps = &AdapterCaps;
    AdapterInit.ObjectAttributes = &Attr;

    // Start the initialization of the adapter, which will trigger the AdapterFinishInit callback later
    IDARG_OUT_ADAPTER_INIT AdapterInitOut;
    NTSTATUS Status = IddCxAdapterInitAsync(&AdapterInit, &AdapterInitOut);

    if (NT_SUCCESS(Status))
    {
        // Store a reference to the WDF adapter handle
        m_Adapter = AdapterInitOut.AdapterObject;

        // Store the device context object into the WDF object context
        auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(AdapterInitOut.AdapterObject);
        pContext->pContext = this;

        TraceEvents(TRACE_LEVEL_INFORMATION,
            TRACE_DEVICE,
            "%!FUNC! init adapter done");
    }
    else
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DEVICE,
            "%!FUNC! cannot init adapter %!STATUS!",
            Status);
    }
}

NTSTATUS IndirectDeviceContext::PlugInMonitor(const CtlPlugIn* Param)
{
    if (!NikoValidPlugIn(*Param)) return STATUS_INVALID_PARAMETER;
    std::lock_guard<std::mutex> lock(m_Lock);
    if (!NT_SUCCESS(m_AdapterInitStatus.load())) return STATUS_DEVICE_NOT_READY;
    if (m_Monitors[0]) return STATUS_OBJECT_NAME_COLLISION;
    WDF_OBJECT_ATTRIBUTES Attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&Attr, IndirectMonitorContextWrapper);
    Attr.EvtCleanupCallback = [](WDFOBJECT object) {
        WdfObjectGet_IndirectMonitorContextWrapper(object)->Cleanup();
    };
    IDDCX_MONITOR_INFO info = {};
    info.Size = sizeof(info);
    info.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    info.ConnectorIndex = 0;
    info.MonitorDescription.Size = sizeof(info.MonitorDescription);
    info.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
    info.MonitorDescription.DataSize = 0;
    memcpy(&info.MonitorContainerId, Param->ContainerId, sizeof(info.MonitorContainerId));
    IDARG_IN_MONITORCREATE input = {};
    input.ObjectAttributes = &Attr;
    input.pMonitorInfo = &info;
    IDARG_OUT_MONITORCREATE output = {};
    auto status = IddCxMonitorCreate(m_Adapter, &input, &output);
    if (!NT_SUCCESS(status)) return status;
    auto* context = WdfObjectGet_IndirectMonitorContextWrapper(output.MonitorObject);
    context->pContext = new (std::nothrow) IndirectMonitorContext(output.MonitorObject);
    if (!context->pContext) {
        WdfObjectDelete(output.MonitorObject);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    // Swapchain callbacks may start at arrival; install their context first.
    IDARG_OUT_MONITORARRIVAL arrival = {};
    status = IddCxMonitorArrival(output.MonitorObject, &arrival);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(output.MonitorObject);
        return status;
    }
    m_Monitors[0] = output.MonitorObject;
    return STATUS_SUCCESS;
}

NTSTATUS IndirectDeviceContext::PlugOutMonitor(const CtlPlugOut* Param)
{
    if (!NikoValidPlugOut(*Param)) return STATUS_INVALID_PARAMETER;
    std::lock_guard<std::mutex> lock(m_Lock);
    if (!m_Monitors[0]) return STATUS_SUCCESS; // Idempotent cleanup of this adapter only.
    auto status = IddCxMonitorDeparture(m_Monitors[0]);
    if (NT_SUCCESS(status)) m_Monitors[0] = nullptr;
    return status;
}

IndirectMonitorContext::IndirectMonitorContext(_In_ IDDCX_MONITOR Monitor) :
    m_Monitor(Monitor)
{
}

IndirectMonitorContext::~IndirectMonitorContext()
{
    m_ProcessingThread.reset();
}

void IndirectMonitorContext::AssignSwapChain(IDDCX_SWAPCHAIN SwapChain, LUID RenderAdapter, HANDLE NewFrameEvent)
{
    m_ProcessingThread.reset();

    try {
        auto Device = make_shared<Direct3DDevice>(RenderAdapter);
        if (FAILED(Device->Init())) {
            WdfObjectDelete(SwapChain);
            return;
        }
        m_ProcessingThread.reset(new SwapChainProcessor(SwapChain, Device, NewFrameEvent));
    } catch (const std::bad_alloc&) {
        WdfObjectDelete(SwapChain);
    }
}

void IndirectMonitorContext::UnassignSwapChain()
{
    // Stop processing the last swap-chain
    m_ProcessingThread.reset();
}

#pragma endregion

#pragma region DDI Callbacks

_Use_decl_annotations_
VOID
IddNikoDeskIoDeviceControl(WDFDEVICE Device, WDFREQUEST Request, size_t OutputBufferLength, size_t InputBufferLength, ULONG code)
{
    auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(Device);
    if (!wrapper || !wrapper->pContext) {
        WdfRequestComplete(Request, STATUS_DEVICE_NOT_READY);
        return;
    }
    auto* context = wrapper->pContext;
    if (code == IOCTL_NIKO_QUERY && InputBufferLength == 0 && OutputBufferLength == sizeof(CtlQuery)) {
        void* buffer = nullptr;
        auto status = WdfRequestRetrieveOutputBuffer(Request, sizeof(CtlQuery), &buffer, nullptr);
        if (NT_SUCCESS(status)) {
            *static_cast<CtlQuery*>(buffer) = {NIKO_IDD_MAGIC, NIKO_IDD_PROTOCOL, 1, 7,
                context->Ready() ? 1u : 0u};
            WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, sizeof(CtlQuery));
        } else WdfRequestComplete(Request, status);
        return;
    }
    void* buffer = nullptr;
    const size_t expected = code == IOCTL_NIKO_PLUG_IN ? sizeof(CtlPlugIn) : sizeof(CtlPlugOut);
    if ((code != IOCTL_NIKO_PLUG_IN && code != IOCTL_NIKO_PLUG_OUT)
        || InputBufferLength != expected || OutputBufferLength != 0) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return;
    }
    auto status = WdfRequestRetrieveInputBuffer(Request, expected, &buffer, nullptr);
    if (NT_SUCCESS(status)) status = code == IOCTL_NIKO_PLUG_IN
        ? context->PlugInMonitor(static_cast<const CtlPlugIn*>(buffer))
        : context->PlugOutMonitor(static_cast<const CtlPlugOut*>(buffer));
    WdfRequestComplete(Request, status);
}

// TODO: This function may not be called, why?
_Use_decl_annotations_
NTSTATUS IddNikoDeskAdapterInitFinished(IDDCX_ADAPTER AdapterObject, const IDARG_IN_ADAPTER_INIT_FINISHED* pInArgs)
{
    TraceEvents(TRACE_LEVEL_VERBOSE, TRACE_DEVICE, "%!FUNC! called");

    // This is called when the OS has finished setting up the adapter for use by the IddCx driver. It's now possible
    // to report attached monitors.

    auto* pDeviceContextWrapper = WdfObjectGet_IndirectDeviceContextWrapper(AdapterObject);
    auto Status = pInArgs->AdapterInitStatus;
    if (NT_SUCCESS(Status))
    {
        TraceEvents(TRACE_LEVEL_INFORMATION,
            TRACE_DEVICE,
            "%!FUNC! adapter init finished success");


    }
    else
    {
        TraceEvents(TRACE_LEVEL_ERROR,
            TRACE_DEVICE,
            "%!FUNC! adapter init finished failed %!STATUS!",
            Status);
    }

    pDeviceContextWrapper->pContext->SetAdapterInitStatus(Status);
    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddNikoDeskAdapterCommitModes(IDDCX_ADAPTER AdapterObject, const IDARG_IN_COMMITMODES* pInArgs)
{
    TraceEvents(TRACE_LEVEL_VERBOSE, TRACE_DEVICE, "%!FUNC! called");

    UNREFERENCED_PARAMETER(AdapterObject);
    UNREFERENCED_PARAMETER(pInArgs);

    // For the sample, do nothing when modes are picked - the swap-chain is taken care of by IddCx

    // ==============================
    // TODO: In a real driver, this function would be used to reconfigure the device to commit the new modes. Loop
    // through pInArgs->pPaths and look for IDDCX_PATH_FLAGS_ACTIVE. Any path not active is inactive (e.g. the monitor
    // should be turned off).
    // ==============================

    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddNikoDeskParseMonitorDescription(const IDARG_IN_PARSEMONITORDESCRIPTION* input, IDARG_OUT_PARSEMONITORDESCRIPTION* output)
{
    UNREFERENCED_PARAMETER(input);
    UNREFERENCED_PARAMETER(output);
    return STATUS_NOT_SUPPORTED; // This driver only creates EDID-less monitors.
}

_Use_decl_annotations_
NTSTATUS IddNikoDeskMonitorGetDefaultModes(IDDCX_MONITOR MonitorObject, const IDARG_IN_GETDEFAULTDESCRIPTIONMODES* input, IDARG_OUT_GETDEFAULTDESCRIPTIONMODES* output)
{
    UNREFERENCED_PARAMETER(MonitorObject);
    output->DefaultMonitorModeBufferOutputCount = ARRAYSIZE(s_SampleDefaultModes);
    output->PreferredMonitorModeIdx = 0;
    if (input->DefaultMonitorModeBufferInputCount == 0) return STATUS_SUCCESS;
    if (input->DefaultMonitorModeBufferInputCount < ARRAYSIZE(s_SampleDefaultModes)) return STATUS_BUFFER_TOO_SMALL;
    for (DWORD i = 0; i < ARRAYSIZE(s_SampleDefaultModes); ++i) {
        const auto& mode = s_SampleDefaultModes[i];
        input->pDefaultMonitorModes[i] = CreateIddCxMonitorMode(mode.Width, mode.Height, mode.VSync);
    }
    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddNikoDeskMonitorQueryModes(IDDCX_MONITOR MonitorObject, const IDARG_IN_QUERYTARGETMODES* input, IDARG_OUT_QUERYTARGETMODES* output)
{
    UNREFERENCED_PARAMETER(MonitorObject);
    output->TargetModeBufferOutputCount = ARRAYSIZE(s_SampleDefaultModes);
    if (input->TargetModeBufferInputCount == 0) return STATUS_SUCCESS;
    if (input->TargetModeBufferInputCount < ARRAYSIZE(s_SampleDefaultModes)) return STATUS_BUFFER_TOO_SMALL;
    for (DWORD i = 0; i < ARRAYSIZE(s_SampleDefaultModes); ++i) {
        const auto& mode = s_SampleDefaultModes[i];
        input->pTargetModes[i] = CreateIddCxTargetMode(mode.Width, mode.Height, mode.VSync);
    }
    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddNikoDeskMonitorAssignSwapChain(IDDCX_MONITOR MonitorObject, const IDARG_IN_SETSWAPCHAIN* pInArgs)
{
    TraceEvents(TRACE_LEVEL_RESERVED7, TRACE_DEVICE, "%!FUNC! called");

    auto* pMonitorContextWrapper = WdfObjectGet_IndirectMonitorContextWrapper(MonitorObject);
    pMonitorContextWrapper->pContext->AssignSwapChain(pInArgs->hSwapChain, pInArgs->RenderAdapterLuid, pInArgs->hNextSurfaceAvailable);
    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddNikoDeskMonitorUnassignSwapChain(IDDCX_MONITOR MonitorObject)
{
    TraceEvents(TRACE_LEVEL_VERBOSE, TRACE_DEVICE, "%!FUNC! called");

    auto* pMonitorContextWrapper = WdfObjectGet_IndirectMonitorContextWrapper(MonitorObject);
    pMonitorContextWrapper->pContext->UnassignSwapChain();
    return STATUS_SUCCESS;
}

#pragma endregion
