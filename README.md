```

Install-Module plaster

PS C:\WINDOWS\system32> Invoke-Plaster -TemplatePath 'C:\Repos\Public\Plaster_template' -DestinationPath 'C:\Repos\Private'
  ____  _           _
 |  _ \| | __ _ ___| |_ ___ _ __
 | |_) | |/ _` / __| __/ _ \ '__|
 |  __/| | (_| \__ \ ||  __/ |
 |_|   |_|\__,_|___/\__\___|_|
                                            v1.1.3
==================================================
Name of your module: Test-Module
Brief description on this module: This is a test module.
Version number (0.0.0.1): 
Please select folders to include
[P] Public  
[I] Internal  
[C] Classes  
[B] Binaries  
[D] Data  
(default choices are P,I,C)
Choice[0]: 

Destination path: C:\Repos\Private
Setting up your project
   Create Test-Module\Test-Module.psd1
   Create Test-Module\Test-Module.psm1
Creating you folders for module: 
   Create Test-Module\Public\
   Create Test-Module\Internal\
   Create Test-Module\Classes\
Setting up support for Pester
   Verify The required module Pester (minimum version: 3.4.0) is already installed.
   Create Test-Module\Tests\
   Create Test-Module\Tests\Test-Module.tests.ps1

```