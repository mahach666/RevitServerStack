# escape=`

FROM mcr.microsoft.com/dotnet/framework/wcf:4.8-windowsservercore-ltsc2022

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
# Since 2026 Autodesk ships Revit Server as a 7-Zip archive behind a launcher of
# the interactive ODIS setup. The launcher is not run: 7-Zip (console build, its
# SHA-256 is checked) takes out RevitServer.msi together with its files.
# New updates appear at https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/3Gfbmiwn7RrgauBEoTIfWn.html
# (see CONTRIBUTING.md before changing the file names below).
ADD https://github.com/ip7z/7zip/releases/download/26.04/7zr.exe 7zr.exe
ADD "https://damassets.autodesk.net/content/dam/autodesk/external-assets/support-articles/autodesk-revit-server-2027/Revit_Server_2027_win_db.sfx.exe" Revit_Server_2027_win_db.sfx.exe
RUN powershell -NoProfile -Command "if ((Get-FileHash 7zr.exe -Algorithm SHA256).Hash -ne '256FECA8E274E5DA655E2A284FABAFD9F554365EB164862089DACD4E8276D282') { throw '7zr.exe does not match the SHA-256 published for 7-Zip 26.04' }" && `
    .\7zr.exe x Revit_Server_2027_win_db.sfx.exe -oC:\Autodesk\bundle -y RVT_2027_NA_win_db_002_002.7z && `
    .\7zr.exe x C:\Autodesk\bundle\RVT_2027_NA_win_db_002_002.7z -oC:\Autodesk\image -y -r x64\RSVR\* && `
    rd /s /q C:\Autodesk\bundle

WORKDIR /Autodesk/image/x64/RSVR
RUN START /wait msiexec /i RevitServer.msi /q `
    LTW_PROJECT_FOLDER="C:\ProgramData\Autodesk\Revit Server 2027\Projects\" `
    LTW_CACHE_FOLDER="C:\ProgramData\Autodesk\Revit Server 2027\Cache\" `
    LTW_SERVER_TYPE="Accelerator,Host,Admin" `
    ADSK_EULA_STATUS=#1 `
    ADSK_SOURCE_ROOT="C:\Autodesk\image\" `
    INSTALLDIR="C:\Program Files\Autodesk\Revit Server 2027\" `
    REBOOT=ReallySuppress `
    ADSK_SETUP_EXE=1 `
    CLIENTUILEVEL=3 `
    MSICLIENTUSESEXTERNALUI=1

WORKDIR /
RUN echo localhost > "%programdata%/Autodesk/Revit Server 2027/Config/RSN.ini"
RUN rd /s /q C:\Autodesk

EXPOSE 80
