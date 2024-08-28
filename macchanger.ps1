$ErrorActionPreference="SilentlyContinue"

Clear-Host

$Interface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface -eq $true } | ForEach-Object { $_.Name }
# $Interface = Read-Host "Enter Your Connection Interface Name"  ## Uncomment this line if above doesn't get the correct interface name
$CurrentIP = (Get-NetIPAddress -InterfaceAlias $Interface -AddressFamily IPv4).IPAddress

function macchanger {
	function Write-ErrorAndExit {
		param (
			[string]$Message
		)
		Write-Host "Error: $Message" -ForegroundColor Red
		exit 1
	}

	function Generate-RandomMAC {
		# Generate a random MAC address with the first octet set to 02
		$mac = "02" + "-" + 
			   "{0:X2}" -f (Get-Random -Minimum 0 -Maximum 256) + "-" +
			   "{0:X2}" -f (Get-Random -Minimum 0 -Maximum 256) + "-" +
			   "{0:X2}" -f (Get-Random -Minimum 0 -Maximum 256) + "-" +
			   "{0:X2}" -f (Get-Random -Minimum 0 -Maximum 256) + "-" +
			   "{0:X2}" -f (Get-Random -Minimum 0 -Maximum 256)
		return $mac
	}

	function Set-MACAddress {
		param (
			[string]$Interface,
			[string]$NewMAC
		)

		# Get the transport name for the specified interface
		$transportName = (getmac -v | Where-Object { $_ -match "$Interface" }) | ForEach-Object { $_.Trim() -split '\s+' | Select-Object -Last 1 }

		if (-not $transportName) {
			Write-ErrorAndExit "Unable to find the transport name for $Interface"
		}

		# Extract the GUID part from the transport name
		$guidPart = ($transportName -match '{.*}') | Out-Null; $guidPart = $matches[0]

		# Search the registry for the transport name
		$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class"
		$adapterKey = Get-ChildItem -Path $regPath -Recurse | Where-Object { Get-ItemProperty $_.PSPath | Select-String -Pattern $guidPart }

		if (-not $adapterKey) {
			Write-ErrorAndExit "Unable to find the registry key for transport name $guidPart"
		}

		$adapterRegPath = $adapterKey.PSPath
		
		# Set the new MAC address in the registry
		Write-Host "Setting the New MAC Address..."
		New-ItemProperty -Path $adapterRegPath -Name "NetworkAddress" -Value $NewMAC -PropertyType String -Force | Out-Null
		
		# Restart the network adapter after changing the MAC address
		Write-Host "Restarting the network adapter..."
		Restart-NetAdapter -Name $Interface -Confirm:$false
		Start-Sleep -Seconds 2
	}

	function Revert-MACAddress {
		param (
			[string]$Interface
		)

		# Get the transport name for the specified interface
		$transportName = (getmac -v | Where-Object { $_ -match "$Interface" }) | ForEach-Object { $_.Trim() -split '\s+' | Select-Object -Last 1 }

		if (-not $transportName) {
			Write-ErrorAndExit "Unable to find the transport name for $Interface"
		}

		# Extract the GUID part from the transport name
		$guidPart = ($transportName -match '{.*}') | Out-Null; $guidPart = $matches[0]

		# Search the registry for the transport name
		$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class"
		$adapterKey = Get-ChildItem -Path $regPath -Recurse | Where-Object { Get-ItemProperty $_.PSPath | Select-String -Pattern $guidPart }

		if (-not $adapterKey) {
			Write-ErrorAndExit "Unable to find the registry key for transport name $guidPart"
		}

		$adapterRegPath = $adapterKey.PSPath

		# Remove the NetworkAddress entry to revert to the original MAC address
		Write-Host "Restoring MAC address to the original..."
		Remove-ItemProperty -Path $adapterRegPath -Name "NetworkAddress" | Out-Null
		
		# Restart the network adapter after changing the MAC address
		Write-Host "Restarting the network adapter..."
		Restart-NetAdapter -Name $Interface -Confirm:$false
		Start-Sleep -Seconds 1
		
		Write-Host "MAC address restored successfully!"
	}
	
	function Change-IP {
		# Get the current IP address and subnet prefix length for the Wi-Fi interface
		$NetIPConfig = Get-NetIPAddress -InterfaceAlias $Interface -AddressFamily IPv4
		$CurrentIP = $NetIPConfig.IPAddress
		$PrefixLength = $NetIPConfig.PrefixLength
		$Gateway = (Get-NetIPConfiguration -InterfaceAlias $Interface).IPv4DefaultGateway.NextHop
		$DNSServer = (Get-DnsClientServerAddress -InterfaceAlias $Interface).ServerAddresses

		# Function to calculate the subnet mask from the prefix length
		function Get-SubnetMask($prefixLength) {
			$binaryMask = "1" * $prefixLength + "0" * (32 - $prefixLength)
			$maskParts = ($binaryMask -split "(\d{8})" | Where-Object { $_ -match "\d{8}" }) -join "."
			$maskBytes = $maskParts -split "\." | ForEach-Object { [convert]::ToInt32($_, 2) }
			return [IPAddress]::Parse(($maskBytes -join "."))
		}

		$SubnetMask = Get-SubnetMask $PrefixLength
		$SubnetMaskBytes = $SubnetMask.GetAddressBytes()

		# Function to calculate the network address
		function Get-NetworkAddress($ip, $mask) {
			$ipBytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
			$networkBytes = @()
			for ($i = 0; $i -lt $ipBytes.Length; $i++) {
				$networkBytes += ($ipBytes[$i] -band $mask[$i])
			}
			return [System.Net.IPAddress]::Parse(($networkBytes -join "."))
		}

		$NetworkAddress = Get-NetworkAddress $CurrentIP $SubnetMaskBytes
		$NetworkAddressBytes = $NetworkAddress.GetAddressBytes()

		# Generate a random valid IP address within the subnet range
		$random = New-Object System.Random
		$NewIP = $null

		do {
			if ($PrefixLength -ge 24) {
				# For /24 or smaller subnets, only randomize the last octet
				$RandomByte = $random.Next(2, 254)
				$NetworkAddressBytes[3] = $RandomByte
			} elseif ($PrefixLength -ge 16) {
				# For /16 to /23 subnets, randomize the last two octets
				$NetworkAddressBytes[2] = $random.Next($NetworkAddressBytes[2], $NetworkAddressBytes[2] + (2^(24 - $PrefixLength) - 1))
				$NetworkAddressBytes[3] = $random.Next(1, 254)
			} else {
				# For larger subnets, randomize the last two octets
				$NetworkAddressBytes[2] = $random.Next(0, 255)
				$NetworkAddressBytes[3] = $random.Next(1, 254)
			}

			$NewIP = [System.Net.IPAddress]::Parse(($NetworkAddressBytes -join "."))
		} while ($NewIP -eq $CurrentIP -or (Test-Connection -ComputerName $NewIP -Count 1 -Quiet))

		# Confirm the network interface and connection name
		if (-not (Get-NetAdapter -Name $Interface)) {
			Write-ErrorAndExit "Network interface $Interface not found"
		}
		
		# Remove the existing IP configuration
		Write-Host "Clearing previous IP configurations..."
		Remove-NetIPAddress -InterfaceAlias $Interface -Confirm:$false -AddressFamily IPv4

		# Set the new IP address without the default gateway
		Write-Host "Setting the IP address to $NewIP..."
		try {
			New-NetIPAddress -InterfaceAlias $Interface -IPAddress $NewIP -PrefixLength $PrefixLength | Out-Null
		} catch {
			Write-Host "Failed to set new IP without gateway: $_"
			return
		}

		Write-Host "Flushing the DNS..."
		# Flush DNS cache
		Clear-DnsClientCache | Out-Null
		# Clear ARP cache
		netsh interface ip delete arpcache | Out-Null

		# Verify and set the default gateway if necessary
		Write-Host "Checking if the default gateway needs to be set..."
		$CurrentGateway = (Get-NetIPConfiguration -InterfaceAlias $Interface).IPv4DefaultGateway.NextHop
		if ($CurrentGateway -ne $Gateway -or -not $CurrentGateway) {
			Write-Host "Setting the default gateway to $Gateway..."
			try {
				New-NetRoute -InterfaceAlias $Interface -DestinationPrefix "0.0.0.0/0" -NextHop $Gateway *> $null
			} catch {
				Write-Host "Failed to set the default gateway: $_"
			}
		} else {
			Write-Host "Default gateway is already set correctly."
		}
		
		# Set DNS server
		Write-Host "Setting DNS server to $DNSServer..."
		Set-DnsClientServerAddress -InterfaceAlias $Interface -ServerAddresses $DNSServer

		# Verify the changes
		Write-Host "Verifying the new IP address..."
		$VerifiedIP = (Get-NetIPAddress -InterfaceAlias $Interface -AddressFamily IPv4).IPAddress
		if ($VerifiedIP -eq $NewIP) {
			Write-Host "IP address changed successfully to $NewIP"
		} else {
			Write-ErrorAndExit "Failed to change IP address"
		}
		
		Start-Sleep -Seconds 1

		Check internet connectivity
		Write-Host "Checking internet connectivity..."
		if (Test-Connection -ComputerName google.com -Count 2 -Quiet) {
			Write-Host "Internet connectivity is OK"
		} else {
			Write-ErrorAndExit "Internet connectivity failed"
		}
	}
	
	function Restore-IP {
		# Remove any existing static IP configurations
		Remove-NetIPAddress -InterfaceAlias $Interface -AddressFamily IPv4 -Confirm:$false *> $null

		# Set the interface to use DHCP for IP address and DNS
		Set-NetIPInterface -InterfaceAlias $Interface -DHCP Enabled | Out-Null
		Set-DnsClientServerAddress -InterfaceAlias $Interface -ResetServerAddresses | Out-Null

		# Flush DNS cache
		Clear-DnsClientCache | Out-Null
		# Clear ARP cache
		netsh interface ip delete arpcache | Out-Null

	}

	Clear-Host

	Write-Host " 1: Set random MAC Address"
	Write-Host " 2: Restore original MAC Address"
	Write-Host " 3: Change IP Address"
	Write-Host " 4: Restore IP Address/Configuration"
	Write-Host " 5: Show current MAC & IP Address"
	Write-Host " 6: Exit"
	
	$CHOICE = Read-Host ">"

	Clear-Host

	if ($CHOICE.trim() -eq 1) {
		Write-Host "Changing the MAC Address of the interface $Interface..."
		$NewMAC = Generate-RandomMAC
		Set-MACAddress -Interface $Interface -NewMAC $(($NewMAC -replace "-", ""))
		
		# Verify the new MAC address
		$UpdatedMAC = (Get-NetAdapter -Name $Interface).MacAddress
		if ($UpdatedMAC -eq $NewMAC) {
			Write-Host "MAC address changed successfully to $NewMAC"
		} else {
			Write-ErrorAndExit "Failed to change MAC address"
		}
	}
	elseif ($CHOICE.trim() -eq 2) {
		Write-Host "Restoring the MAC Address of the interface $Interface..."
		Revert-MACAddress -Interface $Interface	
	}
	elseif ($CHOICE.trim() -eq 3) {
		Write-Host "Changing the IP Address of the interface $Interface..."
		Change-IP
		Write-Host "IP address change completed successfully."
	}
	elseif ($CHOICE.trim() -eq 4) {
		Write-Host "Resetting the IP Configuration of the interface $Interface..."
		Restore-IP
		Write-Host "Reverted $Interface to DHCP configuration"
	}
	elseif ($CHOICE.trim() -eq 5) {
		Write-Host "Interface: $Interface"
		Write-Host "Current IP Address: $((Get-NetIPAddress -InterfaceAlias $interface -AddressFamily IPv4).IPAddress)" -ForegroundColor "Blue"
		Write-Host "Current MAC Address: $((Get-NetAdapter -Name $Interface).MacAddress)" -ForegroundColor "Blue"
		Pause
		macchanger
	}
	elseif ($CHOICE.trim() -eq 6) {
		return
	}
	else {
		macchanger
	}	
}

# Check if running as admin
function Test-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Not running as administrator! Rerun the script with elevated privileges." -ForegroundColor Red
    exit
}
else {
	macchanger
}
