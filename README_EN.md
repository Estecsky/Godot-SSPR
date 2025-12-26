# Godot-SSPR

Screen Space Planar Reflections (SSPR) Implementation for Godot 4, Supporting Forward+ and Mobile renderers.

![img](./ScreenShot.png)
## Introduction

This project was initiated to implement a low-cost screen space planar reflection effect in Godot that works seamlessly with both Forward+ and Mobile renderers.

Key Features:

- Supports Forward+ and Mobile renderers

- Neighborhood search for hole filling

- Manual TAA implementation to further fill reflection holes (since built-in TAA is unavailable on Mobile)

- Edge fading

- Includes Dual Kawase Blur and Gaussian Blur post-processing effects

Actual Runtime Performance (Tested on RTX 5060ti, 1080P Resolution):

- Without blur enabled:

    - Forward+ : 0.6~0.7ms GPU time

    - Mobile : 0.4~0.5ms GPU time

- With blur enabled (Dual Kawase Blur):

    - Forward+ : 0.9~1ms GPU time

    - Mobile : 0.6~0.7ms GPU time

Mobile Device Testing (Using Test Scene):

- Xiaomi 11 (Snapdragon 888), 1080P, Blur Enabled (Dual Kawase Blur), Avg FPS : 42

- IQOO 15 (Snapdragon 8 Elite Gen 5), 1080P, Blur Enabled (Dual Kawase Blur), Avg FPS : 120

Project File Structure:

- `Material` Folder: Ground material using SSR as reflection shader (for comparison testing only)

- `Mesh` Folder: Contains test mesh models

- `Scene` Folder: Main test scene file and test scene for reconstructing world-space positions using camera raycasting

- `Script` Folder: Contains free camera script and script for testing world-space position reconstruction via camera raycasting

    Free Camera Controls:

    - WASD: Move camera forward/backward/left/right

    - Mouse Movement: Rotate camera

    - Mouse Middle Button: Show/hide mouse cursor

    - Q/E: Move camera up/down

    - ESC: Exit running scene

- `shader` Folder: Contains shaders for world-space position reconstruction via camera raycasting and ground material using SSR as reflection shader


- `SSPR_demo` Folder:

    - `Compute Shader` Folder: Contains all compute shaders for reflection calculation, TAA, and blur post-processing

    - `GDScript` Folder: Compositor post-processing script for SSPR effect

    - `shader` Folder: Shader for ground material using SSPR as reflection method

- `World` Folder: Contains environment map resources

## Usage

- Open the project with Godot 4.5.1 (or a newer version).

## References

Some of the reference materials are Chinese documents.

#### SSPR Architecture

- https://remi-genin.github.io/posts/screen-space-planar-reflections-in-ghost-recon-wildlands/

- https://zhuanlan.zhihu.com/p/651134124

#### TAA References

- https://blog.51cto.com/u_16213647/8761628

#### Dual Kawase Blur References

- https://github.com/QianMo/X-PostProcessing-Library/tree/master/Assets/X-PostProcessing/Effects/DualKawaseBlur

- https://loveforyou.tech/posts/urp-dual-kawase-blur/

#### Godot Compositor Function Code Reference

- https://github.com/BastiaanOlij/RERadialSunRays/blob/master/radial_sky_rays/radial_sky_rays.gd