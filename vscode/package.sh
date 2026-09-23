#!/bin/sh
# Build worklog-<version>.vsix beside this script, and say how to install it.
#
# A vsix is a zip with a manifest at the root and the extension under
# `extension/`, and that is all `code --install-extension` reads, so this is
# `zip` and a here-document rather than `vsce` and its node_modules.
set -eu
cd "$(dirname "$0")"
version=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' package.json)
out="worklog-$version.vsix"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/extension"
cp package.json extension.js README.md "$tmp/extension/"
cat > "$tmp/extension.vsixmanifest" <<MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="worklog" Version="$version" Publisher="vtjnash"/>
    <DisplayName>worklog</DisplayName>
    <Description xml:space="preserve">What wl asks of VS Code that its command line cannot: a diff at a line, and a commit.</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.90.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
MANIFEST
cat > "$tmp/[Content_Types].xml" <<TYPES
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
TYPES
rm -f "$out"
if command -v zip >/dev/null 2>&1; then
    (cd "$tmp" && zip -q -r -X "$OLDPWD/$out" .)
else
    python3 - "$tmp" "$out" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk(src):
        for f in fs:
            p = os.path.join(d, f)
            z.write(p, os.path.relpath(p, src))
PY
fi
echo "wrote vscode/$out"
echo "install it into the VS Code that 'code' reaches:  code --install-extension vscode/$out"
