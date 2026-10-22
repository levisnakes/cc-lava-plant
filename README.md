# Lava Plant

A ComputerCraft program that runs a whole lava setup from one computer:

- pushes cobblestone from Create Cobblestone **Mechanical Generators** into every basin
- drains lava from every **basin** (superheated mixers) into your lava tank
- tops up every Create Propulsion **thruster** from the lava tank
- feeds lava to every **Liquid Burner** (a modem on the end burner of a straight line feeds the whole line)
- pushes water into each **steam boiler** in 1000 mB bursts, which keeps the boiler at water level 18

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-lava-plant/main/lava_plant.lua startup.lua
```

Put a wired modem on every basin, generator, thruster, end burner, the lava tank, the water source and each boiler, and join them with network cable. On first start the program lists your fluid tanks and asks which is the lava tank (L), the water source (W) and the boilers (B). Press **S** to run that setup again.

## Notes

- Thruster modems must be on the intake end. On a 3x3x3 thruster that means one of the 9 intake-layer blocks.
- Burners stop taking lava when the lava tank drops below `THRUSTER_RESERVE_MB`, so thrusters get fuel first.
- The program only updates itself while no thruster is firing.
- Settings are at the top of the file, or in `/config.lua`.
