#!/bin/bash

# Script to retrieve Salesforce metadata in batches of 3 types at a time
# Usage: ./retrieve_metadata_batches.sh [package.xml path] [batch_size]

set -e  # Exit on error

# Configuration
PACKAGE_XML="${1:-manifest/package.xml}"
BATCH_SIZE="${2:-3}"
TEMP_DIR="./temp_manifests"
API_VERSION=$(grep -o '<version>[^<]*' "$PACKAGE_XML" | sed 's/<version>//' | head -1)

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}==================================${NC}"
echo -e "${BLUE}Salesforce Metadata Batch Retriever${NC}"
echo -e "${BLUE}==================================${NC}"
echo ""

# Verify package.xml exists
if [ ! -f "$PACKAGE_XML" ]; then
    echo -e "${RED}Error: Package.xml not found at $PACKAGE_XML${NC}"
    exit 1
fi

# Create temp directory
mkdir -p "$TEMP_DIR"

# Extract all metadata types from package.xml
echo -e "${YELLOW}Extracting metadata types from $PACKAGE_XML...${NC}"
METADATA_TYPES=($(grep -o '<name>[^<]*' "$PACKAGE_XML" | sed 's/<name>//' | grep -v "^$API_VERSION$"))

TOTAL_TYPES=${#METADATA_TYPES[@]}
echo -e "${GREEN}Found $TOTAL_TYPES metadata types${NC}"
echo ""

# Function to create temporary package.xml with specific types
create_temp_package() {
    local types=("$@")
    local temp_package="$TEMP_DIR/package_batch_$BATCH_NUMBER.xml"

    cat > "$temp_package" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
EOF

    # Add each type to the package
    for type_name in "${types[@]}"; do
        # Extract members for this type from original package.xml
        # This handles both wildcard (*) and specific members
        awk -v type="$type_name" '
            /<types>/ { in_types=1; members=""; next }
            in_types && /<members>/ {
                gsub(/<[^>]*>/, "");
                gsub(/^[[:space:]]+|[[:space:]]+$/, "");
                if (members) members = members "\n    <members>" $0 "</members>";
                else members = "    <members>" $0 "</members>";
                next
            }
            in_types && /<name>/ {
                gsub(/<[^>]*>/, "");
                gsub(/^[[:space:]]+|[[:space:]]+$/, "");
                if ($0 == type) {
                    print "    <types>";
                    print members;
                    print "        <name>" type "</name>";
                    print "    </types>";
                }
                in_types=0;
                next
            }
            in_types && /<\/types>/ { in_types=0 }
        ' "$PACKAGE_XML" >> "$temp_package"
    done

    cat >> "$temp_package" <<EOF
    <version>$API_VERSION</version>
</Package>
EOF

    echo "$temp_package"
}

# Process metadata types in batches
BATCH_NUMBER=1
CURRENT_INDEX=0

while [ $CURRENT_INDEX -lt $TOTAL_TYPES ]; do
    # Get batch of types
    BATCH_TYPES=()
    for ((i=0; i<BATCH_SIZE && CURRENT_INDEX<TOTAL_TYPES; i++)); do
        BATCH_TYPES+=("${METADATA_TYPES[$CURRENT_INDEX]}")
        ((CURRENT_INDEX++))
    done

    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}Batch $BATCH_NUMBER (Types $((CURRENT_INDEX-${#BATCH_TYPES[@]}+1)) to $CURRENT_INDEX of $TOTAL_TYPES)${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"

    # Display types in this batch
    for type in "${BATCH_TYPES[@]}"; do
        echo -e "  - ${GREEN}$type${NC}"
    done
    echo ""

    # Create temporary package.xml for this batch
    TEMP_PACKAGE=$(create_temp_package "${BATCH_TYPES[@]}")
    echo -e "${YELLOW}Created temporary manifest: $TEMP_PACKAGE${NC}"

    # Retrieve metadata using Salesforce CLI
    echo -e "${YELLOW}Retrieving metadata...${NC}"

    if sf project retrieve start --manifest "$TEMP_PACKAGE" --wait 30; then
        echo -e "${GREEN}✓ Batch $BATCH_NUMBER completed successfully${NC}"
    else
        echo -e "${RED}✗ Batch $BATCH_NUMBER failed${NC}"
        echo -e "${YELLOW}Continuing with next batch...${NC}"
    fi

    echo ""
    ((BATCH_NUMBER++))
done

# Cleanup
echo -e "${YELLOW}Cleaning up temporary files...${NC}"
rm -rf "$TEMP_DIR"

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Retrieval process completed!${NC}"
echo -e "${GREEN}==================================${NC}"
echo -e "Total batches processed: $((BATCH_NUMBER-1))"
echo -e "Total metadata types: $TOTAL_TYPES"