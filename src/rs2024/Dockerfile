# escape=`

FROM mcr.microsoft.com/dotnet/framework/wcf:4.6.2
	
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

RUN Add-WindowsFeature NET-Framework-45-ASPNET; `
	Add-WindowsFeature NET-WCF-TCP-Activation45; `
    Add-WindowsFeature NET-WCF-HTTP-Activation45; `
    Add-WindowsFeature Web-WebSockets; `
    Add-WindowsFeature Web-ASP; `
    Add-WindowsFeature Web-CGI; `
    Add-WindowsFeature Web-Includes; `
    Add-WindowsFeature Web-Mgmt-Compat; `
    Add-WindowsFeature Web-WMI; `
    Add-WindowsFeature Web-Lgcy-Scripting


SHELL ["CMD", "/C"]

WORKDIR /Autodesk
# ADD Revit_Server_2024_Win_64bit_dlm.sfx.exe Revit_Server_2024_Win_64bit_dlm.sfx.exe
ADD "https://up1.autodesk.com/2024/RVT/5A37FF7C-EA37-3FE6-8EF6-7382D03DEE46/Revit_Server_2024_Win_64bit_dlm.sfx.exe" Revit_Server_2024_Win_64bit_dlm.sfx.exe
# Optional integrity check: docker build --build-arg INSTALLER_SHA256=<SHA-256 of the file>
# fails the build when the downloaded installer is another file. Empty = not checked
# (see "Verifying the installers" in README.md).
ARG INSTALLER_SHA256=
RUN powershell -NoProfile -Command "if ($env:INSTALLER_SHA256 -and (Get-FileHash Revit_Server_2024_Win_64bit_dlm.sfx.exe -Algorithm SHA256).Hash -ne $env:INSTALLER_SHA256) { throw 'Revit_Server_2024_Win_64bit_dlm.sfx.exe does not match INSTALLER_SHA256' }" && `
    START /W Revit_Server_2024_Win_64bit_dlm.sfx.exe -suppresslaunch -d "C:\Autodesk"

WORKDIR /Autodesk/Revit_Server_2024_Win_64bit_dlm/x64/RS2024
RUN START /wait msiexec /i RevitServer.msi /q `
    LTW_PROJECT_FOLDER="C:\ProgramData\Autodesk\Revit Server 2024\Projects\" ` 
    LTW_CACHE_FOLDER="C:\ProgramData\Autodesk\Revit Server 2024\Cache\" `
    LTW_SERVER_TYPE=Accelerator,Host,Admin `
    ADSK_EULA_STATUS=#1 `
    ADSK_SOURCE_ROOT="C:\Autodesk\Revit_Server_2024_Win_64bit_dlm\" `
    INSTALLDIR="C:\Program Files\Autodesk\Revit Server 2024\" `
    REBOOT=ReallySuppress `
    ADSK_SETUP_EXE=1 `
    CLIENTUILEVEL=3 `
    MSICLIENTUSESEXTERNALUI=1

WORKDIR /
RUN echo localhost > "%programdata%/Autodesk/Revit Server 2024/Config/RSN.ini"
RUN rd /s /q C:\Autodesk

EXPOSE 80