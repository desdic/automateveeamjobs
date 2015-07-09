# Automate veeam jobs

The purpose of this scrips is to create a job per VM and a copyjob. Input is in CSV format:

```
	#Hostname,Retention,CopyRestorepoints,CopyWeekly,CopyMonthly,CopyQuaterly,CopyYearly
	myhost1,31,35,2,2,0,0,0
	myhost2,14,2,3,4,5,0
```
