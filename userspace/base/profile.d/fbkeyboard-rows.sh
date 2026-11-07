# fbkeyboard draws its on-screen keyboard over the bottom part of the
# framebuffer.  Shrink the console so shell and program output stay above it
# instead of scrolling underneath the keys.
#
# fbkeyboard uses 5 rows of height = (yres/3 + xres/2) / 10 pixels each, based
# on the *visible* framebuffer size.  Read it from
# /sys/class/graphics/fb0/modes ("U:1080x2340p-0"); virtual_size is 1080,4680
# on this panel because of double buffering and must not be used.
#
# The console font height is not fixed (8x16 by default, 16x32 when
# vconsole.conf loads latarcyrheb-sun32), so derive it from the current tty
# size: font_height = visible_height / current_rows.
if [ -t 1 ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && \
   [ -r /sys/class/graphics/fb0/modes ]; then
    mode=$(head -n1 /sys/class/graphics/fb0/modes 2>/dev/null)
    mode=${mode#*:}          # U:1080x2340p-0 -> 1080x2340p-0
    w=${mode%x*}             # 1080
    rest=${mode#*x}          # 2340p-0
    h=${rest%%[!0-9]*}       # 2340
    sz=$(stty size 2>/dev/null)
    cur_rows=${sz% *}
    if [ -n "$w" ] && [ -n "$h" ] && [ "$h" -gt 0 ] && \
       [ -n "$cur_rows" ] && [ "$cur_rows" -gt 0 ] 2>/dev/null; then
        rowpx=$(( (h / 3 + w / 2) / 10 ))
        kbdpx=$(( rowpx * 5 ))
        fh=$(( h / cur_rows ))
        [ "$fh" -ge 8 ] || fh=16
        kbrows=$(( kbdpx / fh ))
        rows=$(( cur_rows - kbrows - 1 ))
        [ "$rows" -gt 10 ] && stty rows "$rows" 2>/dev/null || true
    fi
fi
