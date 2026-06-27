#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Name of the Windows service that hosts the AmneziaWG tunnel.
constexpr wchar_t kAwgServiceName[] = L"netinetaAWG";

std::wstring ExePath() {
  wchar_t buffer[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  return std::wstring(buffer);
}

std::wstring ExeDir() {
  std::wstring path = ExePath();
  size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
}

// `/tunnelservice <confPath>` — entry point used by the service control
// manager. Loads tunnel.dll (the amneziawg-windows embeddable service) and runs
// the AmneziaWG tunnel from the config file. This call blocks until the service
// is stopped.
int RunTunnelService(const wchar_t* conf_path) {
  HANDLE file = CreateFileW(conf_path, GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return 1;
  }
  DWORD file_size = GetFileSize(file, nullptr);
  std::string utf8(file_size, '\0');
  DWORD read = 0;
  if (file_size > 0) {
    ReadFile(file, &utf8[0], file_size, &read, nullptr);
  }
  CloseHandle(file);
  utf8.resize(read);

  int wide_len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  std::wstring conf16(wide_len > 0 ? wide_len : 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &conf16[0], wide_len);

  std::wstring dll_path = ExeDir() + L"\\tunnel.dll";
  HMODULE dll = LoadLibraryW(dll_path.c_str());
  if (dll == nullptr) {
    return 2;
  }
  using TunnelServiceFn = unsigned char(*)(const wchar_t*, const wchar_t*);
  auto run = reinterpret_cast<TunnelServiceFn>(
      GetProcAddress(dll, "WireGuardTunnelService"));
  if (run == nullptr) {
    return 3;
  }
  run(conf16.c_str(), L"netineta");
  return 0;
}

// `/installawg <confPath>` — (re)create and start the tunnel service. Run by the
// elevated UI process, so it has the rights to manage services.
int InstallAwgService(const wchar_t* conf_path) {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
  if (manager == nullptr) {
    return 1;
  }

  SC_HANDLE existing = OpenServiceW(manager, kAwgServiceName, SERVICE_ALL_ACCESS);
  if (existing != nullptr) {
    SERVICE_STATUS status = {0};
    ControlService(existing, SERVICE_CONTROL_STOP, &status);
    DeleteService(existing);
    CloseServiceHandle(existing);
    Sleep(400);
  }

  std::wstring bin =
      L"\"" + ExePath() + L"\" /tunnelservice \"" + conf_path + L"\"";
  SC_HANDLE service = CreateServiceW(
      manager, kAwgServiceName, L"netineta AmneziaWG", SERVICE_ALL_ACCESS,
      SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL,
      bin.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr);
  if (service == nullptr) {
    CloseServiceHandle(manager);
    return 2;
  }

  BOOL started = StartServiceW(service, 0, nullptr);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return started ? 0 : 3;
}

// `/uninstallawg` — stop and delete the tunnel service.
int UninstallAwgService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
  if (manager == nullptr) {
    return 1;
  }
  SC_HANDLE service = OpenServiceW(manager, kAwgServiceName, SERVICE_ALL_ACCESS);
  if (service != nullptr) {
    SERVICE_STATUS status = {0};
    ControlService(service, SERVICE_CONTROL_STOP, &status);
    DeleteService(service);
    CloseServiceHandle(service);
  }
  CloseServiceHandle(manager);
  return 0;
}

// Handles the non-UI command-line modes. Returns true and sets |exit_code| if
// the process should exit instead of launching the Flutter window.
bool HandleServiceMode(int& exit_code) {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  bool handled = false;
  if (argc >= 2) {
    std::wstring mode = argv[1];
    if (mode == L"/tunnelservice" && argc >= 3) {
      exit_code = RunTunnelService(argv[2]);
      handled = true;
    } else if (mode == L"/installawg" && argc >= 3) {
      exit_code = InstallAwgService(argv[2]);
      handled = true;
    } else if (mode == L"/uninstallawg") {
      exit_code = UninstallAwgService();
      handled = true;
    }
  }
  LocalFree(argv);
  return handled;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // VPN-service command-line modes run without the Flutter UI.
  int service_exit_code = 0;
  if (HandleServiceMode(service_exit_code)) {
    return service_exit_code;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // Client (content) area — the window is fixed at this size and centered.
  Win32Window::Size size(980, 620);
  if (!window.Create(L"netineta", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
