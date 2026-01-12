#!/bin/bash
set -euo pipefail

# =============================================================================
# Codex Sync Script
# Syncs files from a local directory to a Spark Codex with intelligent diffing
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Temp files for inventory
CODEX_INVENTORY=$(mktemp)
LOCAL_INVENTORY=$(mktemp)
TO_ADD=$(mktemp)
TO_UPDATE=$(mktemp)
TO_DELETE=$(mktemp)
UNCHANGED=$(mktemp)

# Cleanup on exit
cleanup() {
    rm -f "$CODEX_INVENTORY" "$LOCAL_INVENTORY" "$TO_ADD" "$TO_UPDATE" "$TO_DELETE" "$UNCHANGED"
}
trap cleanup EXIT

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Build find pattern from file extensions
build_find_pattern() {
    local extensions="$1"
    local pattern=""
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    for i in "${!EXT_ARRAY[@]}"; do
        ext="${EXT_ARRAY[$i]}"
        ext=$(echo "$ext" | xargs) # trim whitespace
        if [ "$i" -eq 0 ]; then
            pattern="-name \"*.$ext\""
        else
            pattern="$pattern -o -name \"*.$ext\""
        fi
    done
    echo "$pattern"
}

# Convert ISO date to epoch seconds for comparison
iso_to_epoch() {
    local iso_date="$1"
    if [ -z "$iso_date" ] || [ "$iso_date" = "null" ]; then
        echo "0"
        return
    fi
    # Handle various ISO formats
    if command -v gdate &> /dev/null; then
        gdate -d "$iso_date" +%s 2>/dev/null || echo "0"
    else
        date -d "$iso_date" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${iso_date%%.*}" +%s 2>/dev/null || echo "0"
    fi
}

# =============================================================================
# Step 1: Fetch Codex Inventory
# =============================================================================

fetch_codex_inventory() {
    log_info "Fetching content inventory from Codex..."

    local page=1
    local page_size=100
    local total_fetched=0

    # Clear inventory file
    > "$CODEX_INVENTORY"

    while true; do
        response=$(curl -s -f -w "\n%{http_code}" \
            "${API_BASE_URL}/v1/content/filter" \
            -H "Authorization: Bearer ${SPARK_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"codex_id\": \"${CODEX_ID}\", \"page\": ${page}, \"num_items\": ${page_size}}" \
            2>/dev/null) || {
                log_error "Failed to fetch Codex inventory"
                exit 1
            }

        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')

        if [ "$http_code" != "200" ]; then
            log_error "API returned HTTP $http_code"
            echo "$body"
            exit 1
        fi

        # Debug: show response structure
        log_debug "API response data count: $(echo "$body" | jq '.data | length')"
        log_debug "First item structure: $(echo "$body" | jq -c '.data[0] | keys' 2>/dev/null || echo 'N/A')"

        # Parse response and append to inventory
        # Format: content_id<TAB>title<TAB>modified_at
        # Use explicit tab printing to avoid issues with @tsv and special characters
        echo "$body" | jq -r '.data[] | "\(.id // "")\t\(.title // "")\t\(.modified_at // "")"' >> "$CODEX_INVENTORY"

        log_debug "Sample parsed line: $(head -1 "$CODEX_INVENTORY" | cat -A 2>/dev/null || echo 'empty')"

        # Check pagination
        local count=$(echo "$body" | jq '.data | length')
        total_fetched=$((total_fetched + count))

        local total_records=$(echo "$body" | jq '.total_record // 0')

        if [ "$total_fetched" -ge "$total_records" ] || [ "$count" -lt "$page_size" ]; then
            break
        fi

        page=$((page + 1))
    done

    # Validate inventory format and content
    local valid_count=0
    local invalid_count=0
    local corrupted_count=0
    local validated_inventory=$(mktemp)

    while IFS= read -r line; do
        # Count tabs in line - should have exactly 2 tabs (3 fields)
        local tab_count=$(echo "$line" | tr -cd '\t' | wc -c)
        if [ "$tab_count" -ne 2 ]; then
            invalid_count=$((invalid_count + 1))
            if [ "$invalid_count" -le 3 ]; then
                log_warning "Skipping malformed inventory entry: $line"
            fi
            continue
        fi

        # Extract title (second field) and validate it's not a content_id or timestamp
        local title=$(echo "$line" | cut -f2)

        # Skip entries where title looks like a content ID (dc_<uuid> pattern)
        if [[ "$title" =~ ^dc_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            corrupted_count=$((corrupted_count + 1))
            log_debug "Skipping corrupted entry (title is content_id): $title"
            continue
        fi

        # Skip entries where title looks like an ISO timestamp (YYYY-MM-DDTHH:MM:SS pattern)
        if [[ "$title" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
            corrupted_count=$((corrupted_count + 1))
            log_debug "Skipping corrupted entry (title is timestamp): $title"
            continue
        fi

        # Valid entry
        echo "$line" >> "$validated_inventory"
        valid_count=$((valid_count + 1))
    done < "$CODEX_INVENTORY"

    if [ "$invalid_count" -gt 3 ]; then
        log_warning "... and $((invalid_count - 3)) more malformed entries"
    fi

    # Replace inventory with validated version
    mv "$validated_inventory" "$CODEX_INVENTORY"

    local codex_count=$(wc -l < "$CODEX_INVENTORY" | xargs)
    log_success "Found $codex_count valid files in Codex"

    if [ "$invalid_count" -gt 0 ]; then
        log_warning "Skipped $invalid_count malformed entries from API response"
    fi
    if [ "$corrupted_count" -gt 0 ]; then
        log_warning "Skipped $corrupted_count corrupted entries (title was content_id or timestamp)"
    fi
}

# =============================================================================
# Step 2: Build Local Inventory
# =============================================================================

build_local_inventory() {
    log_info "Scanning local directory: $DIRECTORY"

    # Check if directory exists
    if [ ! -d "$DIRECTORY" ]; then
        log_error "Directory does not exist: $DIRECTORY"
        exit 1
    fi

    # Build find command
    local find_pattern=$(build_find_pattern "$FILE_EXTENSIONS")

    # Clear inventory file
    > "$LOCAL_INVENTORY"

    # Find files and get their git timestamps
    eval "find \"$DIRECTORY\" -type f \( $find_pattern \)" | while read -r filepath; do
        local identifier=$(basename "$filepath")

        # Get last commit timestamp for file (or file mtime if not in git)
        local git_date
        git_date=$(git log -1 --format="%cI" -- "$filepath" 2>/dev/null) || true

        if [ -z "$git_date" ]; then
            # Fallback to file modification time
            if [[ "$OSTYPE" == "darwin"* ]]; then
                git_date=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%S" "$filepath")
            else
                git_date=$(stat -c "%y" "$filepath" | cut -d'.' -f1 | tr ' ' 'T')
            fi
        fi

        # Format: identifier<TAB>filepath<TAB>modified_at
        echo -e "${identifier}\t${filepath}\t${git_date}"
    done > "$LOCAL_INVENTORY"

    local local_count=$(wc -l < "$LOCAL_INVENTORY" | xargs)
    log_success "Found $local_count compatible files locally"
}

# =============================================================================
# Step 3: Compute Diff
# =============================================================================

compute_diff() {
    log_info "Computing diff..."

    # Clear diff files
    > "$TO_ADD"
    > "$TO_UPDATE"
    > "$TO_DELETE"
    > "$UNCHANGED"

    # Build associative arrays (using temp files for bash 3 compatibility)
    local codex_ids=$(mktemp)
    local codex_dates=$(mktemp)
    local local_files=$(mktemp)

    # Parse Codex inventory into lookup files
    while IFS=$'\t' read -r content_id title modified_at; do
        echo "$content_id" >> "${codex_ids}.${title}"
        echo "$modified_at" >> "${codex_dates}.${title}"
    done < "$CODEX_INVENTORY"

    # Process local files
    while IFS=$'\t' read -r identifier filepath local_date; do
        echo "$identifier" >> "$local_files"

        local codex_id_file="${codex_ids}.${identifier}"
        local codex_date_file="${codex_dates}.${identifier}"

        if [ -f "$codex_id_file" ]; then
            # File exists in Codex - check if update needed
            local codex_id=$(cat "$codex_id_file")
            local codex_date=$(cat "$codex_date_file")

            local local_epoch=$(iso_to_epoch "$local_date")
            local codex_epoch=$(iso_to_epoch "$codex_date")

            if [ "$local_epoch" -gt "$codex_epoch" ]; then
                # Local is newer - needs update
                echo -e "${identifier}\t${filepath}\t${codex_id}\t${local_date}\t${codex_date}" >> "$TO_UPDATE"
            else
                # Unchanged
                echo -e "${identifier}\t${filepath}\t${codex_id}" >> "$UNCHANGED"
            fi
        else
            # New file
            echo -e "${identifier}\t${filepath}\t${local_date}" >> "$TO_ADD"
        fi
    done < "$LOCAL_INVENTORY"

    # Find files to delete (in Codex but not locally)
    while IFS=$'\t' read -r content_id title modified_at; do
        if ! grep -q "^${title}$" "$local_files" 2>/dev/null; then
            echo -e "${title}\t${content_id}" >> "$TO_DELETE"
        fi
    done < "$CODEX_INVENTORY"

    # Cleanup temp files
    rm -f ${codex_ids}.* ${codex_dates}.* "$local_files" "$codex_ids" "$codex_dates"
}

# =============================================================================
# Step 4: Print Diff Summary
# =============================================================================

print_diff_summary() {
    local add_count=$(wc -l < "$TO_ADD" | xargs)
    local update_count=$(wc -l < "$TO_UPDATE" | xargs)
    local delete_count=$(wc -l < "$TO_DELETE" | xargs)
    local unchanged_count=$(wc -l < "$UNCHANGED" | xargs)

    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                     Codex Sync Diff                        ${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Files to add
    if [ "$add_count" -gt 0 ]; then
        echo -e " ${GREEN}+ ADD${NC} (${add_count} files)"
        while IFS=$'\t' read -r identifier filepath local_date; do
            echo -e "   ${GREEN}•${NC} ${identifier}"
        done < "$TO_ADD"
        echo ""
    fi

    # Files to update
    if [ "$update_count" -gt 0 ]; then
        echo -e " ${YELLOW}↻ UPDATE${NC} (${update_count} files)"
        while IFS=$'\t' read -r identifier filepath codex_id local_date codex_date; do
            echo -e "   ${YELLOW}•${NC} ${identifier}"
            echo -e "     local: ${local_date%T*} → codex: ${codex_date%T*}"
        done < "$TO_UPDATE"
        echo ""
    fi

    # Files to delete
    if [ "$delete_count" -gt 0 ]; then
        if [ "$DELETE_REMOVED" = "true" ]; then
            echo -e " ${RED}- DELETE${NC} (${delete_count} files)"
        else
            echo -e " ${RED}- WOULD DELETE${NC} (${delete_count} files, skipped - delete_removed=false)"
        fi
        while IFS=$'\t' read -r title content_id; do
            echo -e "   ${RED}•${NC} ${title}"
        done < "$TO_DELETE"
        echo ""
    fi

    # Unchanged
    if [ "$unchanged_count" -gt 0 ]; then
        echo -e " ${CYAN}= UNCHANGED${NC} (${unchanged_count} files)"
        echo ""
    fi

    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Summary line
    local total=$((add_count + update_count + delete_count + unchanged_count))
    echo -e "📊 ${BOLD}Summary:${NC} $total total | ${GREEN}+$add_count${NC} | ${YELLOW}↻$update_count${NC} | ${RED}-$delete_count${NC} | ${CYAN}=$unchanged_count${NC}"
    echo ""

    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}🔍 DRY RUN MODE - No changes will be made${NC}"
        echo ""
    fi
}

# =============================================================================
# Step 5: Execute Sync
# =============================================================================

execute_sync() {
    if [ "$DRY_RUN" = "true" ]; then
        log_info "Dry run mode - skipping sync"
        return
    fi

    local add_count=0
    local update_count=0
    local delete_count=0
    local errors=0

    # Delete files that no longer exist locally
    if [ "$DELETE_REMOVED" = "true" ]; then
        while IFS=$'\t' read -r title content_id; do
            log_info "Deleting: $title"
            if curl -s -f -X DELETE \
                "${API_BASE_URL}/v1/content/${content_id}" \
                -H "Authorization: Bearer ${SPARK_API_KEY}" > /dev/null 2>&1; then
                log_success "Deleted: $title"
                delete_count=$((delete_count + 1))
            else
                log_error "Failed to delete: $title"
                errors=$((errors + 1))
            fi
        done < "$TO_DELETE"
    fi

    # Delete then re-upload updated files
    while IFS=$'\t' read -r identifier filepath codex_id local_date codex_date; do
        log_info "Updating: $identifier"

        # Delete existing
        if ! curl -s -f -X DELETE \
            "${API_BASE_URL}/v1/content/${codex_id}" \
            -H "Authorization: Bearer ${SPARK_API_KEY}" > /dev/null 2>&1; then
            log_warning "Failed to delete existing: $identifier (continuing with upload)"
        fi

        # Upload new version
        if curl -s -f -X POST \
            "${API_BASE_URL}/v1/content" \
            -H "Authorization: Bearer ${SPARK_API_KEY}" \
            -F "file=@${filepath}" \
            -F "codex_id=${CODEX_ID}" > /dev/null 2>&1; then
            log_success "Updated: $identifier"
            update_count=$((update_count + 1))
        else
            log_error "Failed to upload: $identifier"
            errors=$((errors + 1))
        fi
    done < "$TO_UPDATE"

    # Upload new files
    while IFS=$'\t' read -r identifier filepath local_date; do
        log_info "Adding: $identifier"

        if curl -s -f -X POST \
            "${API_BASE_URL}/v1/content" \
            -H "Authorization: Bearer ${SPARK_API_KEY}" \
            -F "file=@${filepath}" \
            -F "codex_id=${CODEX_ID}" > /dev/null 2>&1; then
            log_success "Added: $identifier"
            add_count=$((add_count + 1))
        else
            log_error "Failed to upload: $identifier"
            errors=$((errors + 1))
        fi
    done < "$TO_ADD"

    # Print final summary
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                    Sync Complete                           ${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}Added:${NC}   $add_count files"
    echo -e "  ${YELLOW}Updated:${NC} $update_count files"
    echo -e "  ${RED}Deleted:${NC} $delete_count files"
    if [ "$errors" -gt 0 ]; then
        echo -e "  ${RED}Errors:${NC}  $errors"
    fi
    echo ""

    # Set outputs for GitHub Actions
    echo "files_added=$add_count" >> "$GITHUB_OUTPUT"
    echo "files_updated=$update_count" >> "$GITHUB_OUTPUT"
    echo "files_deleted=$delete_count" >> "$GITHUB_OUTPUT"
    echo "files_unchanged=$(wc -l < "$UNCHANGED" | xargs)" >> "$GITHUB_OUTPUT"

    if [ "$errors" -gt 0 ]; then
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}🔄 Codex Sync${NC}"
    echo -e "   Codex ID: ${CODEX_ID}"
    echo -e "   Directory: ${DIRECTORY}"
    echo ""

    fetch_codex_inventory
    build_local_inventory
    compute_diff
    print_diff_summary
    execute_sync
}

main
