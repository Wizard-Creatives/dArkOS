#!/bin/bash
# GameMT E5 Plus: step the stick light rings and button backlights through
# all on -> stick rings off -> all off -> all on.  The choice is remembered
# and put back on every boot by e5plus-lights.service.

printf "\033c" > /dev/tty1
mode="$(sudo /bin/sh /usr/local/bin/e5plus-lights.sh cycle)"
case "$mode" in
  on)         text="Stick rings and button lights are on." ;;
  sticks-off) text="Stick rings are off, button lights are on." ;;
  off)        text="Stick rings and button lights are off." ;;
  *)          text="Could not change the lights." ;;
esac
printf "\n\n\n\e[32m%s\n\e[0mRun Joystick Lights again for the next setting.\n" "$text" > /dev/tty1
sleep 2
printf "\033c" > /dev/tty1
