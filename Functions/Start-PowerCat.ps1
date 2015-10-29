﻿function Start-PowerCat {
[CmdletBinding(DefaultParameterSetName = 'Console')]
    Param (
        [Parameter(Position = 0, Mandatory = $true)]
        [Alias('m')]
        [ValidateSet('Icmp', 'Smb', 'Tcp', 'Udp')]
        [String]$Mode,
        
        [Parameter(ParameterSetName = 'Execute')]
        [Alias('e')]
        [Switch]$Execute,
    
        [Parameter(ParameterSetName = 'Input')]
        [Alias('i')]
        [Object]$Input,
        
        [Parameter(ParameterSetName = 'Relay')]
        [Alias('r')]
        [String]$Relay,

        [Parameter(ParameterSetName = 'OutFile')]
        [Alias('of')]
        [String]$OutputFile,
    
        [Parameter(ParameterSetName = 'OutFile', Mandatory = $true)]
        [Parameter(ParameterSetName = 'Console', Mandatory = $true)]
        [Alias('ot')]
        [ValidateSet('Bytes','String')]
        [String]$OutputType,
    
        [Parameter()]
        [Alias('d')]
        [Switch]$Disconnect,
    
        [Parameter()]
        [Alias('k')]
        [Switch]$KeepAlive,
    
        [Parameter()]
        [Alias('t')]
        [Int]$Timeout = 60,
        
        [Parameter()]
        [ValidateSet('Ascii','Unicode','UTF7','UTF8','UTF32')]
        [String]$Encoding = 'Ascii'
    )       
    DynamicParam {
        $ParameterDictionary = New-Object Management.Automation.RuntimeDefinedParameterDictionary
        
        switch ($Mode) {
           'Icmp' { $BindParam = New-RuntimeParameter -Name BindAddress -Type String -Mandatory -Position 1 -ParameterDictionary $ParameterDictionary -ValidatePattern "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$" ; continue }
            'Smb' { $PipeNameParam = New-RuntimeParameter -Name PipeName -Type String -Mandatory -ParameterDictionary $ParameterDictionary ; continue }
            'Tcp' { $PortParam = New-RuntimeParameter -Name Port -Type Int -Mandatory -Position 1 -ParameterDictionary $ParameterDictionary ; continue }
            'Udp' { $PortParam = New-RuntimeParameter -Name Port -Type Int -Mandatory -Position 1 -ParameterDictionary $ParameterDictionary ; continue }
        }

        if ($Execute.IsPresent) { 
            $ScriptBlockParam = New-RuntimeParameter -Name ScriptBlock -Type ScriptBlock -ParameterDictionary $ParameterDictionary 
            $ArgumentListParam = New-RuntimeParameter -Name ArgumentList -Type Object[] -ParameterDictionary $ParameterDictionary 
        }

        return $ParameterDictionary
    }
    Begin {         
        switch ($Encoding) {
            'Ascii' { $EncodingType = New-Object Text.AsciiEncoding ; continue }
          'Unicode' { $EncodingType = New-Object Text.UnicodeEncoding ; continue }
             'UTF7' { $EncodingType = New-Object Text.UTF7Encoding ; continue }
             'UTF8' { $EncodingType = New-Object Text.UTF8Encoding ; continue }
            'UTF32' { $EncodingType = New-Object Text.UTF32Encoding ; continue }
        }
      
        if ($PSCmdlet.ParameterSetName -eq 'Input') {   
            
            Write-Verbose 'Parsing input...'

            if ((Test-Path $Input)) { $BytesToSend = [IO.File]::ReadAllBytes($Input) }     
            elseif ($Input.GetType() -eq [Byte[]]) { $BytesToSend = $Input }
            elseif ($Input.GetType() -eq [String]) { $BytesToSend = $EncodingType.GetBytes($Input) }
            else { Write-Warning 'Incompatible input type.' ; return }
        }

        elseif ($PSCmdlet.ParameterSetName -eq 'Relay') {
            
            Write-Verbose "Setting up relay stream..."

            $RelayConfig = $Relay.Split(':')

            if ($RelayConfig.Count -eq 2) { # Listener
                
                $RelayMode = $RelayConfig[0].ToLower()

                switch ($RelayMode) {
                   'icmp' { $RelayStream = New-IcmpStream -Listener $RelayConfig[1] ; continue }
                    'smb' { $RelayStream = New-SmbStream -Listener $RelayConfig[1] ; continue }
                    'tcp' { $RelayStream = New-TcpStream -Listener $RelayConfig[1] ; continue }
                    'udp' { $RelayStream = New-UdpStream -Listener $RelayConfig[1] ; continue }
                    default { Write-Warning 'Invalid relay mode specified.' ; return }
                }
            }
            elseif ($RelayConfig.Count -eq 3) { # Client
                
                $RelayMode = $RelayConfig[0].ToLower()
                $ServerIp = [Net.IPAddress]::Parse($RemoteIp)

                switch ($RelayMode) {
                   'icmp' { $RelayStream = New-IcmpStream $ServerIp $RelayConfig[2] ; continue }
                    'smb' { $RelayStream = New-SmbStream $RelayConfig[1] $RelayConfig[2] ; continue }
                    'tcp' { $RelayStream = New-TcpStream $ServerIp $RelayConfig[2] ; continue }
                    'udp' { $RelayStream = New-UdpStream $ServerIp $RelayConfig[2] ; continue }
                    default { Write-Warning 'Invalid relay mode specified.' ; return }
                }
            }
            else { Write-Error 'Invalid relay format.' -ErrorAction Stop }
        }
          
        elseif ($ParameterDictionary.ScriptBlock.Value) {
            
            Write-Verbose 'Executing scriptblock...'

            $ScriptBlock = $ParameterDictionary.ScriptBlock.Value
            
            $Error.Clear()
            
            $BytesToSend += $EncodingType.GetBytes(($ScriptBlock.Invoke($ParameterDictionary.ArgumentList.Value) | Out-String))
            if ($Error) { foreach ($Err in $Error) { $BytesToSend += $EncodingType.GetBytes($Err.ToString()) } }
            $BytesToSend += $EncodingType.GetBytes(("`nPS $((Get-Location).Path)> "))
            
            $ScriptBlock = $null
        }

        Write-Verbose "Setting up network stream..."

        switch ($Mode) {
           'Icmp' { 
                try { $InitialBytes, $ServerStream = New-IcmpStream -Listener $ParameterDictionary.BindAddress.Value }
                catch { Write-Warning "Failed to open Icmp stream. $($_.Exception.Message)" ; return }
                continue 
            }
            'Smb' { 
                try { $ServerStream = New-SmbStream -Listener $ParameterDictionary.PipeName.Value  }
                catch { Write-Warning "Failed to open Smb stream. $($_.Exception.Message)" ; return }
                continue 
            }
            'Tcp' { 
                if ((Test-Port -Number $ParameterDictionary.Port.Value -Transport Tcp)) {
                    try { $ServerStream = New-TcpStream -Listener $ParameterDictionary.Port.Value }
                    catch { Write-Warning "$($_.Exception.Message)" }
                }
                continue 
            }
            'Udp' { 
                if ((Test-Port -Number $ParameterDictionary.Port.Value -Transport Udp)) {
                    try { $InitialBytes, $ServerStream = New-UdpStream -Listener $ParameterDictionary.Port.Value }
                    catch { Write-Warning "Failed to open Udp stream. $($_.Exception.Message)" ; return }
                }
            }
        }
      
        if ($BytesToSend.Count) { Write-NetworkStream $Mode $ServerStream $BytesToSend }
    }
    Process {   
        [console]::TreatControlCAsInput = $true        
    
        if ($Disconnect.IsPresent) { Write-Verbose 'Disconnect specified, exiting.' ; break }

        while ($true) {
            
            # Catch Ctrl+C / Read-Host
            if ([console]::KeyAvailable) {          
                $Key = [console]::ReadKey()
                if ($Key.Key -eq [Consolekey]::Escape) {
                    Write-Warning 'Caught escape sequence, stopping PowerCat.'
                    break
                }
                if ($PSCmdlet.ParameterSetName -eq 'Console') { 
                    $BytesToSend = $EncodingType.GetBytes($Key.KeyChar + (Read-Host) + "`n") 
                    Write-NetworkStream $Mode $ServerStream $BytesToSend
                }
            }

            # Get data from the network
            if ($InitialBytes) { $ReceivedBytes = $InitialBytes ; $InitialBytes = $null }
            elseif ($ServerStream.Socket.Connected) { 
                if ($ServerStream.Read.IsCompleted) { $ReceivedBytes = Read-NetworkStream $Mode $ServerStream $ServerStream.Socket.Available } 
                else { Start-Sleep -Milliseconds 1 ; continue }
            }
            elseif ($ServerStream.Pipe.IsConnected) { 
                if ($ServerStream.Read.IsCompleted) { $ReceivedBytes = Read-NetworkStream $Mode $ServerStream } 
                else { Start-Sleep -Milliseconds 1 ; continue }
            }
            else { Write-Warning 'Connection broken, exiting.' ; break }

            # Redirect received bytes
            if ($PSCmdlet.ParameterSetName -eq 'Execute') {
            
                $ScriptBlock = [ScriptBlock]::Create($EncodingType.GetString($ReceivedBytes))
            
                $Error.Clear()

                $BytesToSend += $EncodingType.GetBytes(($ScriptBlock.Invoke() | Out-String))
                if ($Error) { foreach ($Err in $Error) { $BytesToSend += $EncodingType.GetBytes($Err.ToString()) } }
                $BytesToSend += $EncodingType.GetBytes(("`nPS $((Get-Location).Path)> "))
            
                Write-NetworkStream $Mode $ServerStream $BytesToSend 
                $BytesToSend = $null
                $ScriptBlock = $null
                continue
            }
            elseif ($PSCmdlet.ParameterSetName -eq 'Relay') { Write-NetworkStream $RelayMode $RelayStream $ReceivedBytes ; continue }
            elseif ($PSCmdlet.ParameterSetName -eq 'OutFile') { 
                if ($OutputType -eq 'Bytes') { 
                    $FileStream = New-Object IO.FileStream -ArgumentList @($OutputFile, [IO.FileMode]::Append)
                    [void]$FileStream.Seek(0, [IO.SeekOrigin]::End) 
                    $FileStream.Write($ReceivedBytes, 0, $ReceivedBytes.Length) 
                    $FileStream.Flush() 
                    $FileStream.Dispose() 
                    continue
                }
                else { $EncodingType.GetString($ReceivedBytes) | Out-File -Append -FilePath $OutputFile ; continue }
            }
            else { # StdOut
                if ($OutputType -eq 'Bytes') { Write-Output $ReceivedBytes }
                else { Write-Host -NoNewline $EncodingType.GetString($ReceivedBytes).TrimEnd("`r") }
            }
        }
    }
    End {   
        [console]::TreatControlCAsInput = $false

        Write-Verbose 'Attempting to close network stream.'
      
        try { Close-NetworkStream $Mode $ServerStream }
        catch { Write-Warning "Failed to close client stream. $($_.Exception.Message)" }

        if ($PSCmdlet.ParameterSetName -eq 'Relay') {
            try { Close-NetworkStream $RelayMode $RelayStream }
            catch { Write-Warning "Failed to close relay stream. $($_.Exception.Message)" }
        }
    }
}