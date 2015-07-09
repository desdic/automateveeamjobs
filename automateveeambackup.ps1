asnp "VeeamPSSnapIn" -ErrorAction SilentlyContinue
Add-PSSnapin VMware.VimAutomation.Core

# Global vars
# Show debug info
$DebugPreference = "Continue"
#$DebugPreference = "SilentlyContinue"

$veeamrepository = "veeam_repos01";
$veeamretention = "veeam_retention01";
$jobnameprefix = "Backup Job ";
$copyjobnameprefix = "Backup Copy Job ";

#Set schedule options (Random between these hours)
$backuphours = (23,'00','01','02','03','04');

$vminjobs = @{}
$ballerup=1
$taastrup=0
# Arrays in powershell are fucked
$proxies = @(@(),@())

# Lets create an array of proxies and devide them into taastrup and ballerup. Proxy with 1 as a 3rd digit is a proxy in Ballerup and the rest is in Taastrup
$proxylist = Get-VBRViProxy
foreach ($srv in $proxylist) {

    if ($srv.Name -match '\d+\.\d+\.(\d+)\.\d+') {
        if ($matches[1] -eq $ballerup) {
            $proxies[$ballerup] += ,$srv.Name
        } else {
            $proxies[$taastrup] += ,$srv.Name
        }
    }
}



function SanityCheck {

    $jobs = Get-VBRJob
    foreach ($job in $jobs) {
        $jobname = $job.Name;
        $jobtype = $job.JobTargetType
        Write-Debug("Doing sanitycheck on job ""$jobname"" type ""$jobtype""")

        # Check for number of VMs but do not check if the first backup is not done yet
        $backups = (Get-VBRBackup -Name $jobname)
        if ($backups) {
            $numberofvms = $backups.VmCount;
            if ($numberofvms -ne 1) {
                Write-Warning ("Job ""$jobname"" contains more or less than one VM, skipping!");
                continue;
            }
        } else {
            Write-Debug("Skipping ""$jobname"" because the first backup has not run yet")
            continue
        }

        $option = $job.GetOptions()
        $retention = $option.BackupStorageOptions.RetainDays

        if ($jobtype -eq "Backup") {
            $objects = $job.GetObjectsInJob()
            $vmname = $objects.Name;

#            if ($vmname -notmatch "^XXXX-" ){
#                Write-Warning("$vmname does not match a XXXX number");
#            }

            $currentjobs = ($backups).GetStorages() | Select-Object -Property `
            @{N="Name";E={$_.FileName}},`
            @{N="Date";E={$_.CreationTime}},`
            @{N="DataSize";E={$_.Stats.DataSize}},`
            @{N="BackupSize";E={$_.Stats.BackupSize}},`
            @{N="De-dupe Ratio";E={$_.Stats.DedupRatio}},`
            @{N="Compress Ratio";E={$_.Stats.CompressRatio}}

            #Write-Debug ($currentjobs|sort -property Date|Format-Table|Out-String);

            $numberofbackups = (@($currentjobs).Count);
            if ($numberofbackups -lt $retention) {
                Write-Warning ("The job ""$jobname"" has $numberofbackups versions of ""$vmname"" which is less than the the configured number of versions ($retention)");
            } else {
                Write-Debug ("The job ""$jobname"" has $numberofbackups versions of ""$vmname"" out of $retention as set in retention");
            }
        } else {
            Write-Debug("Unable to handle backup copy jobs right now");
        }

    }
}

function CreateCopyJobs {
    $jobs = Get-VBRJob| where {$_.jobtargettype -eq “Backup”};

    foreach ($job in $jobs) {
        $jobid=$job.Id
        $jobname = $job.Name;

        Write-Debug("Found job ""$jobname"", checking for a copy job of this job")

        $backups = (Get-VBRBackup -Name $jobname)
        # No reason to check for a copy job for backups that has never been running (Simply you cannot create a copyjob for a job that has no backups)
        if ($backups) {
            #Write-Debug ($backups|Format-Table|Out-String);
            $numberofvms = $backups.VmCount;

            $vmname = $objects.Name;

            if ($numberofvms -eq 1) {


                # Search for a copy job linked to the backup job
                $copyjob = Get-VBRJob| where {$_.jobtargettype -eq “BackupSync” -and $_.LinkedJobIDs -match $jobid};
                if ($copyjob){
                        $copyjobname = $copyjob.Name
                        Write-Debug("Copyjob ""$copyjobname"" is a copy job for ""$jobname""")
                } else {
                        Write-Debug("We did not find a copy job for job ""$jobname"" so lets create one")

                        $currentjobs = ($backups).GetStorages() | Select-Object -Property `
                        @{N="Name";E={$_.FileName}},`
                        @{N="Date";E={$_.CreationTime}},`
                        @{N="DataSize";E={$_.Stats.DataSize}},`
                        @{N="BackupSize";E={$_.Stats.BackupSize}},`
                        @{N="De-dupe Ratio";E={$_.Stats.DedupRatio}},`
                        @{N="Compress Ratio";E={$_.Stats.CompressRatio}}


                        $numberofbackups = @($currentjobs).Count
                        $latestresult = $job.GetLastResult()

                        if ($numberofbackups -gt 0 -and $latestresult -notmatch "Failed") {
                            $copyjobname = $jobname -replace " Job ", " Copy Job "

                            Add-VBRViBackupCopyJob -DirectOperation -Name $copyjobname -BackupJob $jobname -Repository (Get-VBRBackupRepository -Name $veeamretention)

                            $job = Get-VBRJob | where {$_.name -eq $copyjobname}
                            $joboptions = Get-VBRJobOptions $job

                            $copyrestorepoints = 0
                            $copyweekly = 0
                            $copymonthly = 0
                            $copyquaterly = 0
                            $copyyearly = 0

                            foreach ($vm in $vms) {

                                if ($vmname.Substring(0,9) -eq $vm.Hostname) {
                                    Write-Debug("Found $vmname so we set copyjob so se we the restorepoints, weekly etc")
                                    $copyrestorepoints = $vm.CopyRestorePoints
                                    $copyweekly = $vm.CopyWeekly
                                    $copymonthly = $vm.CopyMonthly
                                    $copyquaterly = $vm.CopyQuaterly
                                    $copyyearly = $vm.CopyYearly
                                    break
                                }

                            }


                            # Set options
                            # ref http://forums.veeam.com/powershell-f26/new-job-options-such-as-generation-policy-options-t17608.html
                            $joboptions.GenerationPolicy.RetentionPolicyType="GFS"
                            $joboptions.GenerationPolicy.GFSWeeklyBackups = $copyweekly
                            $joboptions.GenerationPolicy.GFSMonthlyBackups = $copymonthly
                            $joboptions.GenerationPolicy.GFSQuarterlyBackups = $copyquaterly
                            $joboptions.GenerationPolicy.GFSYearlyBackups = $copyyearly
                            $joboptions.GenerationPolicy.SimpleRetentionRestorePoints = $copyrestorepoints

                            # Extra options commented out but could be usefull in the long run
                            #$joboptions.BackupStorageOptions.CompressionLevel = 1;
                            #$joboptions.BackupStorageOptions.RetainCycles = $csvrentention; #This is the number of restore points kept
                            #$joboptions.JobOptions.SourceProxyAutoDetect = $true;
                            #$joboptions.JobOptions.RunManually = $false;
                            #$joboptions.BackupStorageOptions.RetainDays = 30 # This is how long a deleted VMs files are retained
                            #$joboptions.BackupStorageOptions.EnableDeduplication = $true;
                            #$joboptions.BackupStorageOptions.StgBlockSize = "KbBlockSize512";

                            #$joboptions.BackupTargetOptions.Algorithm = "Increment";
                            #$joboptions.BackupTargetOptions.TransformToSyntethicDays = ((Get-Date).adddays((Get-Random -Minimum 0 -Maximum 6))).dayofweek;
                            #$joboptions.BackupTargetOptions.TransformIncrementsToSyntethic = $true;
                            $job | Set-VBRJobOptions -Options $joboptions


                            # Add scheduler
                            $jobscheduleoptions = Get-VBRJobScheduleOptions $job
                            $jobscheduleoptions.OptionsDaily.Enabled = $true
                            $job | Set-VBRJobScheduleOptions -Options $jobscheduleoptions
                            $job.EnableScheduler()


                        } else {
                            Write-Warning("We cannot create a copy job of ""$jobname"" because there is no data to copy")
                        }
                }
            } else {
                Write-Warning("This job has more than one VM so we did not create this, doing nothing");
            }
        }
    }

}


If ((Get-PSSnapin VeeamPSSnapin).Version.Major -ne 8) {
	Write-Host "You must be running VBR v8 to run this script...Exiting"
	Exit
}


#Read csv file
# Format:
#Hostname,Retention,CopyRestorepoints,CopyWeekly,CopyMonthly,CopyQuaterly,CopyYearly
#myhost1,31,35,2,2,0,0,0
#myhost2,14,2,3,4,5,0

# Read CSV file
$vms = Import-Csv C:\Users\kgn.scl\Desktop\vm.csv


SanityCheck
CreateCopyJobs

foreach ($vm in $vms) {
    $csvvmname = $vm.Hostname;
    $csvrentention = $vm.Retention;

#    if ($csvvmname -notmatch "^XXXX-" ){
#        Write-Warning("$csvvmname does not match a XXXX number, skipping");
#        continue;
#    }

    # Only list Backup and not BackupSync (Copy jobs)
    $jobs = Get-VBRJob| where {$_.jobtargettype -eq “Backup”};

    $donotcreatejob = 0;

    foreach ($job in $jobs) {

        # No need to process if we found errors
        if ($donotcreatejob -ne 0) {
            continue;
        }

        $jobname = $job.Name;

        Write-Debug("Searching for objects in job ""$jobname""");

        # Get job options
        $option = $job.GetOptions();
        $retention = $option.BackupStorageOptions.RetainCycles;

        $backup = (Get-VBRBackup -Name $jobname)
        $joblist = Get-VBRJob -name $jobname

        foreach($jobobject in $joblist)
        {
            $objects = $jobobject.GetObjectsInJob()
            $vmname = $objects.Name;
            $numberofvms = $backup.VmCount;

            # No need to process if we found errors
            if ($donotcreatejob -ne 0) {
                continue;
            }

            if ($vmname.Substring(0,9) -eq $csvvmname) {
                if ($numberofvms -ne 1) {
                    Write-Error("""$jobname"" has the vm ""$csvvmname"" but the job has more than one VM ($numberofvms) meaning this is a bug");
                } elseif ($retention -ne $csvrentention) {
                    Write-Error("""$jobname"" has the vm ""$csvvmname"" but retention is set to $retention but should be $csvrentention");
                } else {
                    Write-Debug("""$jobname"" already has a backup of $csvvmname, skipping");
                }
                $donotcreatejob++;
            }
        }
    }

    if ($donotcreatejob -eq 0) {
        Write-Debug("Oki, we did not find any job with the VM ""$csvvmname"" so lets find it in the vcenter");

        # Search all vcenters connected to this veeam installation
        $vcenters = Get-VBRServer -Type VC;

        $vm = '';
        $vmcount = 0;
        foreach ($vcenter in $vcenters) {

            $address = $vcenter.Name;

            Write-Debug ("Connecting to ""$address""");

            $search = $csvvmname + "*";

            $vm = Find-VBRViEntity -Server $address -VMsAndTemplates -Name $search
            if (!$vm)  {
                Write-Debug("Unable to find a VM by the name ""$search"" at $address");
                continue;
            }

            $vmcount++;
        }

        if ($vmcount -eq 1) {
            Write-Warning("We found a single VM that matches so now we are creating a job");
            Write-Debug ($vm|Format-Table|Out-String);

            $jobname = $jobnameprefix + $csvvmname;

            # Create a job
            Write-Warning("Creating job - $jobname of "+ $vm.Name)
            Add-VBRViBackupJob -Name $jobname -BackupRepository (Get-VBRBackupRepository -Name $veeamrepository) -Entity (Find-VBRViEntity -Name $vm.Name)

            # Get default options and modify them
            $job = Get-VBRJob | where {$_.name -eq $jobname}
            $joboptions = Get-VBRJobOptions $job


            $joboptions.JobOptions.SourceProxyAutoDetect = $true;
            $proxy =''

            $a = Get-VM -Name $vm.Name

            Write-Debug("VM got these dists" + $a.HardDisks)

            # Choose a random proxy based on where the VM is located
            if ($a.HardDisks.Filename -match '_taa_') {
                $joboptions.JobOptions.SourceProxyAutoDetect = $false;
                $proxy = $proxies[$taastrup][(Get-Random -Minimum 0 -Maximum $proxies[$taastrup].Length)]

            } elseif ($a.HardDisks.Filename -match '_bal_') {
                $joboptions.JobOptions.SourceProxyAutoDetect = $false;
                $proxy = $proxies[$ballerup][(Get-Random -Minimum 0 -Maximum $proxies[$ballerup].Length)]
            }


            $joboptions.BackupStorageOptions.RetainCycles = $csvrentention; #This is the number of restore points kept

            $joboptions.JobOptions.RunManually = $false;
            $joboptions.BackupStorageOptions.RetainDays = $csvrentention # This is how long a deleted VMs files are retained
            $joboptions.BackupStorageOptions.EnableDeduplication = $true;
            $joboptions.BackupStorageOptions.StgBlockSize = "KbBlockSize512";
            $joboptions.BackupStorageOptions.CompressionLevel = 0;
            $joboptions.BackupTargetOptions.Algorithm = "Increment";
            $joboptions.BackupTargetOptions.TransformToSyntethicDays = ((Get-Date).adddays((Get-Random -Minimum 0 -Maximum 6))).dayofweek;
            $joboptions.BackupTargetOptions.TransformIncrementsToSyntethic = $true;
            $job | Set-VBRJobOptions -Options $joboptions

            #Randomize backup time
            $hours = $backuphours | Get-Random | Out-String
            $minutes = "{0:D2}" -f (Get-Random -Minimum 0 -Maximum 59) | Out-String
            $time = ($hours+':'+$minutes+':00').replace("`n","")

            Write-Warning("Setting schedule time to $time ")

            # Add scheduler
            $jobscheduleoptions = Get-VBRJobScheduleOptions $job
            $jobscheduleoptions.OptionsDaily.Enabled = $true
            $jobscheduleoptions.OptionsDaily.Kind = "Everyday"
            $jobscheduleoptions.OptionsDaily.Time = $time
            $jobscheduleoptions.NextRun = $time
            $jobscheduleoptions.StartDateTime = $time
            $job | Set-VBRJobScheduleOptions -Options $jobscheduleoptions
            $job.EnableScheduler()


            # Remove all other proxyes then the one we have selected
            if ($proxy -ne '') {

                Write-Debug ("Proxy ""$proxy"" was choosen");

                $ProxyType = 0
                $ProxyToAdd = Get-VBRViProxy| ?{$_.Name –eq $proxy}
                $Proxies= Get-VbrViProxy | ?{$_.Name –ne $ProxyToAdd}

                foreach($ProxytoDelete in $Proxies)
                {
                    foreach($ProxyInfo in ([Veeam.Backup.DBManager.CDBManager]::Instance.JobProxies.GetJobProxies($job.id, $ProxyType)))
                    {
                        if($ProxyInfo.ProxyId -eq $ProxyToDelete.id)
                        {
                            [Veeam.Backup.DBManager.CDBManager]::Instance.JobProxies.Delete($ProxyInfo.id)
                        }
                    }
                }
                [Veeam.Backup.Core.CJobProxy]::Create($Job.id, $ProxyToAdd.id, $ProxyType)


            }
            # We cannot create a copyjob before the first backup is done

        } elseif ($vmcount -eq 0) {
            Write-Error("We did not find any VM with that name on any vcenter connected!");
        } else {
           Write-Error("Found more than one VM matching this name, this is bad!");
        }
    }
}

