#!powershell
# This file is part of Ansible
#
# Copyright 2014, Phil Schwartz <schwartzmx@gmail.com>
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# WANT_JSON
# POWERSHELL_COMMON

$domain = $false
$workgroup = $false
$creds = $false

$params = Parse-Args $args;

$result = New-Object psobject @{
    win_host = New-Object psobject
    changed = $false
}

# Remove account from ActiveDirectory on domain controller
If ($params.rm -eq "true" -Or $params.rm -eq "yes") {
    If ($params.hostname) {
        $user = $params.hostname.toString()
        Try {
          Import-Module ActiveDirectory
        }
        Catch {
          Fail-Json $result "Error importing module ActiveDirectory.  Please ensure this is being run on a domain controller with Active Directory installed."
        }
        Try {
          ([ADSI]([ADSISearcher]"samaccountname=$user`$").FindOne().Path).PSBase.DeleteTree()
        }
        Catch {
            Fail-Json $result "An error occured when attempting to remove account: $user"
        }
    }
    Else {
        Fail-Json $result "missing required argument for AD computer removal: hostname"
    }
}
# Continue as normal
Else {
    If ($params.timezone) {
        Try {
            C:\Windows\System32\tzutil /s $params.timezone.toString()
            $result.changed = $true
        }
        Catch {
            Fail-Json $result "Error setting timezone to: $params.timezone. Example: Central Standard Time"
        }
    }

    # Can enter just one, or as a comma seperated list
    If ($params.hostname) {
        $hostname = $params.hostname.toString().split(",")
        Set-Attr $result.win_host "hostname" $hostname.toString()
        $computername = "-ComputerName '$hostname'"

        If ($hostname.length -eq 1 -and -Not([System.Net.Dns]::GetHostName() -eq $hostname[0])) {
            $newname = "-NewName '$hostname'"
        }
    }
    # None entered? Use current hostname
    Else {
        $hostname = [System.Net.Dns]::GetHostName()
        Set-Attr $result.win_host "hostname" $hostname.toString()
        $computername = "-ComputerName '$hostname'"
    }

    If ($params.domain) {
        $domain = $params.domain.toString()
        Set-Attr $result.win_host "domain" $domain
        If ($domain -eq (gwmi WIN32_ComputerSystem).Domain) {
            Exit-Json $result "The computer is already apart of the domain: $domain."
        }
        $domain = "-DomainName '$domain'"


        If ($params.server) {
            $server = $params.server.toString()
            Set-Attr $result.win_host "server" $server
            $server = "-Server '$server'"
        }
        Else {
            $server = ""
        }

        If ($params.options) {
            $options = $params.options.toString()
            Set-Attr $result.win_host "options" $options
            $options = "-Options '$options'"
        }
        Else {
            $options = ""
        }

        If ($params.oupath) {
            $oupath = $params.oupath.toString()
            Set-Attr $result.win_host "oupath" $oupath
            $oupath = "-OUPath '$oupath'"
        }
        Else {
            $oupath = ""
        }

        If (($params.unsecure -eq "true") -or ($params.unsecure -eq "yes")) {
            $unsecure = $params.unsecure.toString()
            Set-Attr $result.win_host "unsecure" $unsecure
            $unsecure = "-Unsecure"
        }
        Else {
            $unsecure = ""
        }
    }
    Else {
        $domain = ""
    }

    If ($params.workgroup) {
        $workgroup = $params.workgroup.toString()
        Set-Attr $result.win_host "workgroup" $workgroup
        $workgroup = "-WorkgroupName '$workgroup'"
    }
    Else {
        Set-Attr $result.win_host "workgroup" "WORKGROUP"
        $workgroup = "-WorkgroupName 'WORKGROUP'"
    }

    If ($params.user -and $params.pass) {
        $user = $params.user.toString()
        $pass = $params.pass.toString()
        $credential = "-Credential"
        $unjoincredential = "-UnjoinDomainCredential"
        $local = "-LocalCredential"

        $creds = $true
    }

    If (($params.restart -eq "true") -or ($params.restart -eq "yes")) {
        $restart = $true
        Set-Attr $result.win_host "restart" "true"
    }
    Else {
        Set-Attr $result.win_host "restart" "false"
        $restart = $false
    }

    If ($params.state -eq "present") {
        $state = $true
        Set-Attr $result.win_host "state" "present"
    }
    ElseIf ($params.state -eq "absent") {
        $state = $false
        Set-Attr $result.win_host "state" "absent"
    }
    Else {
        $state = "none"
    }

    # If just hostname was provided and not credentials and there was only one hostname just rename computer
    If ($hostname -and -Not ($credential) -and -Not ($domain -Or $workgroup) -and $hostname.length -eq 1) {
        Rename-Computer $hostname[0]
        $result.changed = $true
    }
    # Domain
    ElseIf ($hostname -and $domain){
        If ($creds) {
            If ($state -eq $true) {
                # Check if already a member of the domain
                If ((gwmi win32_computersystem).domain -eq $domain) {
                    Exit-Json $result "The computer(s) $hostname is/are already a member of $domain."
                }
                If ($workgroup) {
                    Try {
                        # If only one hostname was entered, use the new computer parameter to do a rename and domain join in one step
                        If ($newname) {
                            $computername = $newname
                        }
                        $cmd = "Add-Computer $computername $workgroup $credential (New-Object System.Management.Automation.PSCredential $($user),(convertto-securestring $($pass) -asplaintext -force)) -Force"
                        Invoke-Expression $cmd
                        $cmd = "Add-Computer $computername $domain $credential (New-Object System.Management.Automation.PSCredential $($user),(convertto-securestring $($pass) -asplaintext -force)) $server $options $oupath $unsecure -Force"
                        Invoke-Expression $cmd
                        $result.changed = $true
                    }
                    Catch {
                        Fail-Json $result "an error occured when adding $hostname to $workgroup, and then adding to $domain. command attempted --> $cmd"
                    }
                }
                Else {
                    Try{
                        # If only one hostname was entered, use the new computer parameter to do a rename and domain join in one step
                        If ($newname) {
                            $computername = $newname
                        }
                        $cmd = "Add-Computer $computername $domain $credential (New-Object System.Management.Automation.PSCredential $($user),(convertto-securestring $($pass) -asplaintext -force)) $server $options $oupath $unsecure -Force"
                        Invoke-Expression $cmd
                        $result.changed = $true
                    }
                    Catch {
                        Fail-Json $result "an error occured when adding $computername to $domain.  command attempted --> $cmd"
                    }
                }
            }
            ElseIf ($state -eq $false) {
                If ($workgroup) {
                    Try {
                        # Remove from Domain
                        $cmd = "Remove-Computer $computername $workgroup $unjoincredential (New-Object System.Management.Automation.PSCredential $($user),(convertto-securestring $($pass) -asplaintext -force)) -Force"
                        Invoke-Expression $cmd

                        #TODO Remove Disabled Account from Computers Group in AD
                    }
                    Catch {
                        Fail-Json $result "an error occured when unjoining $hostname from domain. command attempted --> $cmd"
                    }
                }
                Else {
                    Fail-Json $result "missing required param: workgroup.  A workgroup must be specified to join after unjoining $domain"
                }
            }
            Else {
                Fail-Json $result "missing a required argument for domain joining/unjoining: state"
            }
        }
        Else {
            Fail-Json $result "missing a required argument for domain joining/unjoining: user and/or pass"
        }
    }
    # Workgroup change only
    ElseIf ($hostname -and $workgroup -and (-Not $domain)){
        If ($creds) {
            Try{
                $cmd = "Add-Computer $computername $workgroup $credential (New-Object System.Management.Automation.PSCredential $($user),(convertto-securestring $($pass) -asplaintext -force)) -Force"
                Invoke-Expression $cmd
                $result.changed = $true
            }
            Catch {
                Fail-Json $result "an error occured when adding $computername to $workgroup.  command attempted --> $cmd"
            }
        }
        Else {
            Fail-Json $result "missing a required argument for workgroup joining/unjoining: user or pass"
        }
    }
    # No state was provided
    Else {
        Fail-Json $result "missing required argument for domain/workgroup joining/unjoining: state"
    }

    # Flush and re-register so that the DNS changes take place
    If ($result.changed) {
        ipconfig /flushdns
        ipconfig /registerdns
    }

    # Restart for changes to take effect
    If ($restart) {
        Restart-Computer -Force
    }
}

Exit-Json $result;
