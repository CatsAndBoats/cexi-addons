# XIVBar [Ported and Updated by Tirem]
A player hp/mp/tp bar addon originally for Windower4 that I updated and ported to Ashita v4 <3

Original Windower4 addon by Edeon [https://github.com/Windower/Lua/tree/live/addons/xivbar]

## Show Your Support ##
If you would like to show your support for my addon creation and porting consider buying me (Tirem) a coffee! 

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/A0A6JC40H)

## Overview

This addon displays vital bars for easy tracking

![alt text](http://i.imgur.com/QA6WSUY.png)

You can choose from 3 different styles 'ffxiv', 'ffxi' and 'ffxiv-legacy'.

![alt text](http://i.imgur.com/vMlZoAl.png)

and you can use a compact version for a smaller resolution:

![alt text](http://i.imgur.com/0vgfDq1.png)

## Installation
* Download the latest release from the panel on the right. Please download the top option on the release page.
* Extract the folder and drop the addons folder within into the install location of Ashita v4
* Load using "/addon load xivbar" in the chat window
* To load the addon automatically when the game starts, edit scripts/default.txt and add "/addon load xivbar" at the end
* RECOMMENDED: Download and install the free font "[Grammara](https://www.fontspace.com/grammara-font-f4454)" for a more authentic FF14 look of the numbers (restart Ashita afterwards, or it won't find the newly installed font)
* NOTE: You will NOT be able to load this addon if you download it from the CODE button above, as it relies on git submodules to function. Please always download from the release page on the right!

## Available Settings
##### Bars
* **Offset X** - moves the entire addon left (negative number) or right (positive number) the given number of pixels
* **Offset Y** - moves the entire addon up (negative number) or down (positive number) the given number of pixels

##### Theme
* **Name** - Name of the theme to use - 'ffxi', 'ffxiv', 'ffxiv-legacy', or your own custom one
* **Compact** - Enables or disables compact mode
* **Bar** - Values for bar width, spacing, offset and compact mode. Useful for creating a custom theme. 

##### Texts
* **Color** - The font color for the HP, MP and TP numbers
* **Font** - The font for the HP, MP and TP numbers
* **Offset** - moves the HP, MP and TP numbers left (negative number) or right (positive number) the given number of pixels
* **Size** - The font size for the HP, MP and TP numbers
* **Stroke** - The font stroke the HP, MP and TP numbers
* **FullTpColor** - The font color for the TP numbers when the bar is full
* **DimTpBar** - dim the TP bar when not full

## How to edit the settings
* You can directly edit most settings in the in game config (/xivbar, or /xb)
* To edit these settings and more manually: 
1. Login to your character in FFXI
2. Edit the addon's settings file: **[GameInstallLocation]\config\addons\xivbar\settings.lua**
3. Save the file 
5. Type ``` /addon reload xivbar ``` to reload the addon

## How to create my own custom theme
1. Create a folder inside the *theme* directory of the addon: **[GameInstallLocation]\addons\xivbar\themes\MY_CUSTOM_THEME**
2. Create the necessary images. A theme is composed of 5 images: a background for the bars (*bar_bg.png*), a background for the compact mode (*bar_compact.png*), and one image for each bar (*hp_fg.png, mp_fg.png and tp_fg.png*). You can take a look at the default themes.
3. Edit the name of the theme in the settings to yours. This setting must match the name of the folder you just created.
4. Adjust the bar width, spacing and offset for your custom theme in the settings.
