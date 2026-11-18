[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
$out = [ordered]@{}
$out.SystemManufacturer = (Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue).SystemManufacturer
$out.SystemBiosVersion = (Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System' -ErrorAction SilentlyContinue).SystemBiosVersion
$out.VideoBiosVersion = (Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System' -ErrorAction SilentlyContinue).VideoBiosVersion
$out.ProcessorNameString = (Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).ProcessorNameString
$scsi = @{}
Get-ChildItem -Path 'HKLM:\HARDWARE\DEVICEMAP\Scsi' -ErrorAction SilentlyContinue | ForEach-Object {
    $scsi[$_.PSChildName] = (Get-ItemProperty -Path $_.PSPath).Driver
}
$out.ScsiPortDrivers = $scsi
$out.DiskDrives = @(Get-CimInstance Win32_DiskDrive | Select-Object Model, Name)
$out.CDRoms = @(Get-CimInstance Win32_CDROMDrive | Select-Object Name, Drive)
$out.VideoControllers = @(Get-CimInstance Win32_VideoController | Select-Object Name, Description, PNPDeviceID)
$out.PnPEntityNames = @(Get-CimInstance Win32_PnPEntity | Select-Object -ExpandProperty Name | Where-Object { $_ -match 'QEMU|VBOX|VMware|Virtual|VirtIO|XEN|Bochs|Red Hat|Parallels' })
$out.ComputerSystem = @(Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model)
$out.Bios = @(Get-CimInstance Win32_BIOS | Select-Object Manufacturer, SMBIOSBIOSVersion)
$out | ConvertTo-Json -Depth 5 -Compress
