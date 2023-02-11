# .bash_profile

# Get the aliases and functions
[ -f $HOME/.bashrc ] && . $HOME/.bashrc
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx
