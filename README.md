# vagrant_vm_control
Enable auto stop and start of vagrant Boxes

To show all options use
> $ vm_control.pl --help|h|?

## Add watched user
To add a user to the watch user run
> \# vm_control.pl --user username

you can add Virtual Machines for the user in the same step
> \# vm_control.pl --user username --box box_id ...

to remove a box from a user profile use
> \# vm_control.pl --user username --rmb box_id ...

to remove a user
> \# vm_control.pl --rmu username
The Following Modules are needed:
> File::HomeDir

> Getopt::Long

> Pod::Usage
