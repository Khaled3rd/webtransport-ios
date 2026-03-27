#!/usr/bin/env python3
"""
Toy controller — receives drive commands from the streamer via Unix domain socket.

Protocol:
  Bind:    /tmp/toy.sock
  Receive: {"d": "u"|"d"|"l"|"r"|"s"}
  d = up / down / left / right / stop
"""
import socket
import json
import os
import sys


TOY_SOCK = "/tmp/toy.sock"

# --- Hardware control ---
# Replace the body of drive() with your actual GPIO / motor calls.
# Examples (uncomment as needed):
#
#   import RPi.GPIO as GPIO
#   import gpiozero (CamJamKitRobot, Motor, etc.)
#
def drive(direction: str) -> None:
    """Apply direction to toy motors."""
    labels = {"u": "FORWARD", "d": "BACKWARD", "l": "LEFT", "r": "RIGHT", "s": "STOP"}
    print(f"[toy] {labels.get(direction, direction)}", flush=True)

    # TODO: replace with real hardware control, e.g.:
    # if direction == "u":
    #     left_motor.forward(); right_motor.forward()
    # elif direction == "d":
    #     left_motor.backward(); right_motor.backward()
    # elif direction == "l":
    #     left_motor.backward(); right_motor.forward()
    # elif direction == "r":
    #     left_motor.forward(); right_motor.backward()
    # else:  # stop
    #     left_motor.stop(); right_motor.stop()


# --- Main loop ---
def main() -> None:
    # Clean up stale socket
    try:
        os.unlink(TOY_SOCK)
    except FileNotFoundError:
        pass

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(TOY_SOCK)
    print(f"[toy] listening on {TOY_SOCK}", flush=True)

    try:
        while True:
            data = sock.recv(4096)
            try:
                msg = json.loads(data)
            except json.JSONDecodeError:
                print(f"[toy] bad JSON: {data!r}", flush=True)
                continue

            direction = msg.get("d", "s")
            drive(direction)
    except KeyboardInterrupt:
        print("\n[toy] stopped", flush=True)
    finally:
        sock.close()
        try:
            os.unlink(TOY_SOCK)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
