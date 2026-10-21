package pairing

import (
	"fmt"
	"strings"

	"rsc.io/qr"
)

// The QR spec asks for four modules of light margin; scanners struggle without it on dark terminals.
const quietZone = 4

// RenderQR draws the code with half blocks, two modules per character row, so it fits a terminal.
// Dark modules are drawn as spaces on a light block background, which reads the same on light and
// dark terminal themes.
func RenderQR(text string) (string, error) {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return "", fmt.Errorf("drawing the pairing code: %w", err)
	}
	light := func(x, y int) bool {
		if x < 0 || y < 0 || x >= code.Size || y >= code.Size {
			return true
		}
		return !code.Black(x, y)
	}
	var out strings.Builder
	for y := -quietZone; y < code.Size+quietZone; y += 2 {
		for x := -quietZone; x < code.Size+quietZone; x++ {
			top, bottom := light(x, y), light(x, y+1)
			switch {
			case top && bottom:
				out.WriteRune('█')
			case top:
				out.WriteRune('▀')
			case bottom:
				out.WriteRune('▄')
			default:
				out.WriteRune(' ')
			}
		}
		out.WriteRune('\n')
	}
	return out.String(), nil
}
