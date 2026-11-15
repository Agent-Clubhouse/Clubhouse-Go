# Desktop theme contrast samples

`builtin-palettes.json` records all 48 built-in desktop palettes, including the seven theme packs,
from Agent-Clubhouse/Clubhouse commit `20ee0a600180c946b5e683af24c7560b48148ecb`,
`src/renderer/themes`. It includes the original nine themes and Aurora, Canyon, Daybreak and Mist.
Only color tokens and accent-gradient stops are copied. The source theme files had no local edits.

These are test inputs, never a registry shipped in the phone app. Custom and future desktop themes
still map from their received tokens. The package test checks both iPhone appearances for every
sample, plus the default Clubhouse Go palette. The hosted visual test renders light, dark,
Solarized Dark, Mocha on light, Cyberpunk and accessibility text with the production palette.
