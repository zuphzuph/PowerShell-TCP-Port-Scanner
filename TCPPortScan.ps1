[CmdletBinding()]
param(
    [Parameter(
        Position=0,
        Mandatory=$true,
        HelpMessage='DNS or IP')]
    [String]$ComputerName,

    [Parameter(
        Position=1,
        HelpMessage='First port (Default=1)')]
    [ValidateRange(1,1023)]
    [Int32]$StartPort=1,

    [Parameter(
        Position=2,
        HelpMessage='Last port (Default=1023)')]
    [ValidateRange(1,1023)]
    [ValidateScript({
        if($_ -lt $StartPort)
        {
            throw "Invalid Port-Range!"
        }
        else 
        {
            return $true
        }
    })]
    [Int32]$EndPort=1023,

    [Parameter(
        Position=3,
        HelpMessage='Max number of threads (Default=5000)')]
    [Int32]$Threads=5000,

    [Parameter(
        Position=4,
        HelpMessage='Execute script without user interaction')]
    [switch]$Force
)

Begin{
    Write-Verbose -Message "Script started at $(Get-Date)"
    $PortList_Path = "ports.txt"
}

Process{
    if(Test-Path -Path $PortList_Path -PathType Leaf)
    {        
        $PortsHashTable = @{ }
        Write-Verbose -Message "Read ports.txt and fill hash table..."
        foreach($Line in Get-Content -Path $PortList_Path)
        {
            if(-not([String]::IsNullOrEmpty($Line)))
            {
                try{
                    $HashTableData = $Line.Split('|')
                    
                    if($HashTableData[1] -eq "tcp")
                    {
                        $PortsHashTable.Add([int]$HashTableData[0], [String]::Format("{0}|{1}",$HashTableData[2],$HashTableData[3]))
                    }
                }
                catch [System.ArgumentException] { }
            }
        }
        $AssignServiceWithPort = $true
    }
    else 
    {
        $AssignServiceWithPort = $false    
        Write-Warning -Message "No port-file to assign service with port found! Execute the script ""Create-PortListFromWeb.ps1"" to download the latest version.. This warning doesn`t affect the scanning procedure."
    }

    Write-Verbose -Message "Test if host is reachable..."
    if(-not(Test-NetConnection -ComputerName $ComputerName -Port 443))
    {
        Write-Warning -Message "$ComputerName is not reachable!"

        if($Force -eq $false)
        {
            $Title = "Continue"
            $Info = "Would you like to continue?"
            
            $Options = [System.Management.Automation.Host.ChoiceDescription[]] @("&Yes", "&No")
            [int]$DefaultChoice = 0
            $Opt =  $host.UI.PromptForChoice($Title , $Info, $Options, $DefaultChoice)

            switch($Opt)
            {                    
                1 { 
                    return
                }
            }
        }
    }
    $PortsToScan = ($EndPort - $StartPort)
    Write-Verbose -Message "Scanning range from $StartPort to $EndPort ($PortsToScan Ports)"
    Write-Verbose -Message "Running with max $Threads threads"

    $IPv4Address = [String]::Empty
	if([bool]($ComputerName -as [IPAddress]))
	{
		$IPv4Address = $ComputerName
	}
	else
	{
		try{
			$AddressList = @(([System.Net.Dns]::GetHostEntry($ComputerName)).AddressList)
			
			foreach($Address in $AddressList)
			{
				if($Address.AddressFamily -eq "InterNetwork") 
				{					
					$IPv4Address = $Address.IPAddressToString 
					break					
				}
			}					
		}
		catch{ }				

       	if([String]::IsNullOrEmpty($IPv4Address))
		{
			throw "Could not get IPv4-Address for $ComputerName. (Try to enter an IPv4-Address instead of the Hostname)"
		}		
	}

    [System.Management.Automation.ScriptBlock]$ScriptBlock = {
        Param(
			$IPv4Address,
			$Port
        )
        try{                      
            $Socket = New-Object System.Net.Sockets.TcpClient($IPv4Address,$Port)
            
            if($Socket.Connected)
            {
                $Status = "Open"             
                $Socket.Close()
            }
            else 
            {
                $Status = "Closed"    
            }
        }
        catch{
            $Status = "Closed"
        }   

        if($Status -eq "Open")
        {
            [pscustomobject] @{
                Port = $Port
                Protocol = "tcp"
                Status = $Status
            }
        }
    }
    Write-Verbose -Message "Setting up RunspacePool..."

    $RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Threads, $Host)
    $RunspacePool.Open()
    [System.Collections.ArrayList]$Jobs = @()
    Write-Verbose -Message "Setting up Jobs..."
    
    foreach($Port in $StartPort..$EndPort)
    {
        $ScriptParams =@{
			IPv4Address = $IPv4Address
			Port = $Port
		}

        try {
			$Progress_Percent = (($Port - $StartPort) / $PortsToScan) * 100 
		} 
		catch { 
			$Progress_Percent = 100 
		}

        Write-Progress -Activity "Setting up jobs..." -Id 1 -Status "Current Port: $Port" -PercentComplete ($Progress_Percent)
        
        $Job = [System.Management.Automation.PowerShell]::Create().AddScript($ScriptBlock).AddParameters($ScriptParams)
        $Job.RunspacePool = $RunspacePool   
        $JobObj = [pscustomobject] @{
            RunNum = $Port - $StartPort
            Pipe = $Job
            Result = $Job.BeginInvoke()
        }

        [void]$Jobs.Add($JobObj)
    }
    Write-Verbose -Message "Waiting for jobs to complete & starting to process results..."

    $Jobs_Total = $Jobs.Count

    Do {
        $Jobs_ToProcess = $Jobs | Where-Object -FilterScript {$_.Result.IsCompleted}
  
        if($null -eq $Jobs_ToProcess)
        {
            Write-Verbose -Message "No jobs completed, wait 100ms..."

            Start-Sleep -Milliseconds 100
            continue
        }
        
        $Jobs_Remaining = ($Jobs | Where-Object -FilterScript {$_.Result.IsCompleted -eq $false}).Count

        try {            
            $Progress_Percent = 100 - (($Jobs_Remaining / $Jobs_Total) * 100) 
        }
        catch {
            $Progress_Percent = 100
        }
        Write-Progress -Activity "Waiting for jobs to complete... ($($Threads - $($RunspacePool.GetAvailableRunspaces())) of $Threads threads running)" -Id 1 -PercentComplete $Progress_Percent -Status "$Jobs_Remaining remaining..."
        Write-Verbose -Message "Processing $(if($null -eq $Jobs_ToProcess.Count){"1"}else{$Jobs_ToProcess.Count}) job(s)..."

        foreach($Job in $Jobs_ToProcess)
        {       
            $Job_Result = $Job.Pipe.EndInvoke($Job.Result)
            $Job.Pipe.Dispose()

            $Jobs.Remove($Job)
           
            if($Job_Result.Status)
            {        
                if($AssignServiceWithPort)
                {
                    $Service = [String]::Empty

                    $Service = $PortsHashTable.Get_Item($Job_Result.Port).Split('|')
                
                    [pscustomobject] @{
                        Port = $Job_Result.Port
                        Protocol = $Job_Result.Protocol
                        ServiceName = $Service[0]
                        ServiceDescription = $Service[1]
                        Status = $Job_Result.Status
                    }
                }   
                else 
                {
                    $Job_Result    
                }             
            }
        } 

    } While ($Jobs.Count -gt 0)
    Write-Verbose -Message "Closing RunspacePool and free resources..."

    $RunspacePool.Close()
    $RunspacePool.Dispose()
    Write-Verbose -Message "Script finished at $(Get-Date)"
}
