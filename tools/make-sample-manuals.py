#!/usr/bin/env python3
"""Write three sample manuals for demoing the machine guide (Manuals app).

They are DEMO documents written for this project, not the manufacturers'
manuals. Usage (from the repo root):
  python3 tools/make-sample-manuals.py        # -> docs/sample-manuals/*.pdf
"""
import os

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer

OUT = "docs/sample-manuals"
ACCENT = colors.HexColor("#C4622D")
INK = colors.HexColor("#1C1B1A")

base = getSampleStyleSheet()
TITLE = ParagraphStyle("T", parent=base["Title"], fontSize=30, leading=36, textColor=INK, alignment=0)
SUB = ParagraphStyle("S", parent=base["Normal"], fontSize=14, leading=20, textColor=ACCENT)
H1 = ParagraphStyle("H1", parent=base["Heading1"], fontSize=18, leading=24, textColor=INK, spaceBefore=6)
BODY = ParagraphStyle("B", parent=base["Normal"], fontSize=11.5, leading=17, textColor=INK)
STEP = ParagraphStyle("St", parent=BODY, leftIndent=8 * mm, firstLineIndent=-8 * mm, spaceAfter=5)
WARN = ParagraphStyle("W", parent=BODY, backColor=colors.HexColor("#FBEDE4"), borderPadding=6,
                      leftIndent=3 * mm, rightIndent=3 * mm, spaceBefore=6, spaceAfter=10)
NOTE = ParagraphStyle("N", parent=BODY, fontSize=9.5, leading=14, textColor=colors.HexColor("#6E6A64"))


def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 8.5)
    canvas.setFillColor(colors.HexColor("#6E6A64"))
    canvas.drawString(20 * mm, 12 * mm, f"{doc.title}  -  sample manual for demonstration")
    canvas.drawRightString(A4[0] - 20 * mm, 12 * mm, f"Page {doc.page}")
    canvas.restoreState()


def build(filename, name, model_line, identify, parts, sections):
    """sections: [(title, warning or None, [steps])] - one section per page."""
    doc = SimpleDocTemplate(os.path.join(OUT, filename), pagesize=A4, title=name,
                            leftMargin=20 * mm, rightMargin=20 * mm, topMargin=22 * mm, bottomMargin=22 * mm)
    story = [Spacer(1, 30 * mm), Paragraph(name, TITLE), Spacer(1, 4 * mm),
             Paragraph(model_line, SUB), Spacer(1, 14 * mm),
             Paragraph("Setup and service guide", H1),
             Paragraph("How to recognise this device", H1)]
    story += [Paragraph(line, BODY) for line in identify]
    story += [Spacer(1, 6 * mm), Paragraph("Parts and tools", H1)]
    story += [Paragraph("&bull; " + p, BODY) for p in parts]
    story += [Spacer(1, 10 * mm), Paragraph(
        "Sample document written to demonstrate the Hermes Glasses machine guide. "
        "It is not the manufacturer's manual; check the official manual before servicing a real device.", NOTE)]
    n = 0
    for title, warning, steps in sections:
        story += [PageBreak(), Paragraph(title, H1)]
        if warning:
            story.append(Paragraph("<b>Caution.</b> " + warning, WARN))
        for step in steps:
            n += 1
            story.append(Paragraph(f"<b>Step {n}.</b> {step}", STEP))
    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    print("wrote", os.path.join(OUT, filename))


os.makedirs(OUT, exist_ok=True)

build(
    "keychron-k8-keyboard.pdf", "Keychron K8 Keyboard", "Wireless mechanical keyboard, tenkeyless, 87 keys",
    ["A compact mechanical keyboard with 87 keys and no number pad. The keycaps are dark grey and light grey, "
     "with an orange Escape key on many units. The word Keychron is printed on the underside.",
     "On the left edge there is a USB-C port and two small slide switches: one marked Win/Android and Mac/iOS, "
     "the other marked BT, Off and Cable. The top-right key carries a light bulb symbol."],
    ["Keychron K8 keyboard", "USB-C cable", "Keycap puller (wire loop tool)", "Switch puller (metal tweezers tool)",
     "Spare Windows and Mac keycaps"],
    [
        ("Section 1. Connect by cable", None, [
            "Find the two slide switches on the left edge of the keyboard, next to the USB-C port.",
            "Slide the operating system switch to Mac/iOS for a Mac, or to Win/Android for a Windows PC.",
            "Slide the mode switch to Cable.",
            "Plug the USB-C cable into the keyboard and into the computer. The keyboard is ready when the backlight comes on.",
        ]),
        ("Section 2. Pair by Bluetooth", None, [
            "Slide the mode switch on the left edge to BT.",
            "Hold the Fn key and the number 1 key together for four seconds, until the backlight under the 1 key flashes quickly.",
            "On the computer, open Bluetooth settings and choose Keychron K8. The flashing stops when pairing is complete.",
            "To pair a second or third device, repeat with Fn and 2, or Fn and 3. The keyboard remembers three devices.",
            "To switch between paired devices, press Fn and the device's number once, without holding.",
        ]),
        ("Section 3. Replace a keycap", "Pull keycaps straight up. Rocking a keycap sideways can bend the switch stem.", [
            "Take the keycap puller, the tool with two wire loops.",
            "Push the wire loops down over the keycap until they click under two opposite corners.",
            "Pull straight up with steady force. The keycap comes off the switch stem.",
            "Line up the new keycap with the cross-shaped stem and press down firmly until it seats.",
            "For the long keys - space bar, Enter, Shift and Backspace - lift both ends evenly, because they sit on a stabiliser bar.",
        ]),
        ("Section 4. Replace a switch (hot-swappable model only)",
         "Unplug the cable and slide the mode switch to Off before removing a switch. "
         "Check both metal pins are straight before inserting a switch; a bent pin will not make contact and can damage the socket.", [
            "Remove the keycap from the switch, following Section 3.",
            "Take the switch puller, the metal tweezers tool. Grip the switch on its top and bottom edges, where the two plastic tabs are.",
            "Squeeze to release the tabs and pull the switch straight up out of the plate.",
            "Inspect the new switch. The two metal pins must be straight and parallel.",
            "Line the pins up with the two holes in the socket, then press the switch straight down until it clicks into the plate.",
            "Refit the keycap, switch the keyboard on and press the key to test it. If nothing happens, remove the switch and check for a bent pin.",
        ]),
        ("Section 5. Backlight, battery and reset", None, [
            "Press the light bulb key at the top right to cycle through the backlight effects.",
            "Press Fn and the light bulb key together to turn the backlight off or on.",
            "Press Fn and B to check the battery. The power light shows green above seventy percent, blue between thirty and seventy, and flashes red below thirty.",
            "Charge with the USB-C cable. The light next to the port is red while charging and green when full.",
            "To factory reset the keyboard, hold Fn, J and Z together for four seconds until the backlight flashes.",
        ]),
    ],
)

build(
    "macbook-pro-m2-pro.pdf", "MacBook Pro M2 Pro", "Apple laptop computer, 14-inch, 2023",
    ["A silver or space grey aluminium laptop with a black keyboard and a large glass trackpad. "
     "The display has thin black borders with a small camera notch at the top centre, and an Apple logo is on the lid.",
     "On the left side are a MagSafe charging port, two Thunderbolt USB-C ports and a headphone jack. "
     "On the right side are an HDMI port, one Thunderbolt USB-C port and an SD card slot. "
     "The words MacBook Pro are engraved on the underside."],
    ["MacBook Pro", "USB-C power adapter", "MagSafe 3 charging cable", "Optional: HDMI or USB-C display cable"],
    [
        ("Section 1. Charge with MagSafe", None, [
            "Plug the USB-C end of the MagSafe cable into the power adapter, and the adapter into a wall socket.",
            "Bring the flat magnetic end of the cable to the MagSafe port, the first port on the left side. It snaps into place.",
            "Check the small light on the connector. Amber means charging, green means fully charged.",
            "To disconnect, pull the connector straight out or tilt it away. The magnet releases without pulling the laptop.",
        ]),
        ("Section 2. Start up and set up Touch ID", None, [
            "Open the lid. The laptop starts by itself. If it does not, press the Touch ID button at the top-right corner of the keyboard.",
            "Follow the setup assistant: choose a language, join a Wi-Fi network and sign in with an Apple ID.",
            "When asked to set up Touch ID, rest a finger on the Touch ID button and lift it repeatedly until the fingerprint picture fills in.",
            "To add another fingerprint later, open System Settings, choose Touch ID and Password, and press Add Fingerprint.",
        ]),
        ("Section 3. Connect an external display", None, [
            "Choose the cable. Use the HDMI port on the right side, or any of the three Thunderbolt USB-C ports.",
            "Plug the cable into the laptop and into the display, then switch the display on.",
            "Open System Settings and choose Displays. The external display appears next to the built-in one.",
            "Press Arrange to drag the displays into the positions they have on the desk.",
            "Choose the external display and set Use As to Extended Display for more space, or Mirror to show the same picture.",
            "This model drives up to two external displays at once.",
        ]),
        ("Section 4. If the laptop stops responding",
         "A forced restart discards unsaved work. Try closing the frozen app first.", [
            "Press Option, Command and Escape together, choose the frozen app and press Force Quit.",
            "If the whole laptop is frozen, press and hold the Touch ID button for about ten seconds until the screen goes black.",
            "Wait a few seconds, then press the Touch ID button once to start again.",
            "To reach the startup options, shut down, then press and hold the Touch ID button until Loading startup options appears.",
        ]),
        ("Section 5. Check battery health and clean the laptop",
         "Never spray liquid directly onto the laptop, and keep moisture out of every opening.", [
            "Open System Settings and choose Battery. Battery Health shows Normal or Service Recommended.",
            "Press the information button next to Battery Health to see the maximum capacity as a percentage.",
            "To clean the screen, shut the laptop down and unplug it.",
            "Wipe the screen with a soft, lint-free cloth dampened with water only.",
            "Wipe the keyboard and case with a dry cloth, then let everything dry before opening the lid again.",
        ]),
    ],
)

build(
    "acer-predator-x34-monitor.pdf", "Acer Predator X34 Monitor", "34-inch curved ultrawide gaming monitor with NVIDIA G-SYNC",
    ["A very wide, curved 34-inch screen with thin black borders. It stands on a silver aluminium stand with two "
     "angled legs that spread out in a V shape. The Predator name and logo are on the bottom edge of the screen.",
     "The back is black with red accents and a strip of lighting along the underside. The ports face downward at "
     "the back: one DisplayPort, one HDMI, a USB hub and the power input. Five control buttons sit under the "
     "bottom-right corner of the screen."],
    ["Monitor with stand", "Power adapter and power cord", "DisplayPort cable", "HDMI cable", "USB upstream cable",
     "Optional: VESA 100 by 100 millimetre mount and a Phillips screwdriver"],
    [
        ("Section 1. Unpack and place the monitor",
         "The curved panel is heavy and fragile. Lift it by the stand and the frame, with two people, and never press on the screen surface.", [
            "Open the box with the screen lying face down on its foam packing.",
            "With a second person, lift the monitor by the stand column and the lower frame and stand it on the desk.",
            "Peel off the protective film from the screen and the stand.",
            "Adjust the height by sliding the screen up or down on the stand column, and tilt it so the top edge is at eye level.",
        ]),
        ("Section 2. Connect the cables",
         "G-SYNC and the high refresh rates work over DisplayPort only. Over HDMI the monitor is limited to sixty hertz and G-SYNC is not available.", [
            "Plug the DisplayPort cable into the DisplayPort socket on the back of the monitor, and into a DisplayPort output on the graphics card - not the motherboard.",
            "Plug the power adapter into the monitor's power input, then connect the power cord to a wall socket.",
            "To use the monitor's USB ports, connect the USB upstream cable from the monitor to a USB port on the computer.",
            "Press the power button, the rightmost button under the bottom-right corner. The light turns blue when a signal is found.",
        ]),
        ("Section 3. Set the resolution and refresh rate", None, [
            "In Windows, right-click the desktop and open Display settings.",
            "Set the resolution to 3440 by 1440, the monitor's native resolution.",
            "Open Advanced display settings and set the refresh rate to sixty hertz to begin with.",
            "On the monitor, press any button under the bottom-right corner to open the on-screen menu.",
            "Open the Setting page, switch Overclock on, and choose the refresh rate: up to one hundred hertz on the X34, or one hundred and twenty hertz on the X34P.",
            "Confirm. The monitor restarts. Return to Advanced display settings in Windows and select the new refresh rate.",
        ]),
        ("Section 4. Turn on G-SYNC", None, [
            "Right-click the desktop and open the NVIDIA Control Panel.",
            "Under Display, choose Set up G-SYNC.",
            "Tick Enable G-SYNC, and choose whether it applies to full screen only or to windowed and full screen mode.",
            "Select the Predator monitor in the list and press Apply.",
            "To confirm it is working, open the Display menu at the top of the NVIDIA Control Panel and tick G-SYNC Compatible Indicator. A label appears on screen when G-SYNC is active.",
        ]),
        ("Section 5. Fit a wall or arm mount",
         "Disconnect all cables first. Support the screen at all times once the stand is unscrewed - it will fall forward.", [
            "Lay a soft cloth on a flat table and place the monitor face down on it.",
            "Remove the four screws that hold the stand to the back of the monitor and lift the stand away.",
            "Fit the VESA adapter plate over the four holes, which are one hundred millimetres apart.",
            "Fasten the mount with four screws, tightening them in a cross pattern until snug. Do not overtighten.",
            "With a second person, lift the monitor onto the arm or wall bracket and reconnect the cables.",
        ]),
    ],
)
