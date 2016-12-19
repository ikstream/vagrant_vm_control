# vagrant_vm_control
Enable auto stop and start of vagrant Boxes

## add watched user
To add a user to the watch user run
> sudo ./vm_control.pl --user \<username\>

you can add Virtual Machines for the user in the same step
> sudo ./vm_control.pl --user \<username\> --box \<box_id\> ...

The Following Modules are needed:
> File::HomeDir

> Getopt::Long

> Pod::Usage
