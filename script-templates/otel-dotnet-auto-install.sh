#!/bin/sh

# Determine the directory of the current script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Script directory: $SCRIPT_DIR"

# Use the SERVICE_NAME variable to determine which properties file to load; default to "service.name1"
SERVICE_NAME="${SERVICE_NAME:-service.name1}"
PROPERTIES_FILE="$SCRIPT_DIR/config/${SERVICE_NAME}.properties"
echo "Properties file: $PROPERTIES_FILE"

# Check if the properties file exists
if [ -f "$PROPERTIES_FILE" ]; then
  echo "Loading properties from $PROPERTIES_FILE"
  # Read the file line by line
  while IFS='=' read -r key value; do
    # Skip empty lines or lines that begin with '#' (comments)
    if [ -z "$key" ] || echo "$key" | grep -q '^\s*#'; then
      continue
    fi
    # Trim leading/trailing whitespace from key and value
    key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Convert property key into a valid shell variable name (e.g. otel.logs.exporter -> OTEL_LOGS_EXPORTER)
    varname=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
    
    # Remove any escaped equal signs from the value
    value=$(echo "$value" | sed 's/\\=//g')
    
    echo "Exporting $varname with value: $value"
    export "$varname"="$value"
    export MOTADATA_INSTALLATION_PATH="$SCRIPT_DIR"
  done < "$PROPERTIES_FILE"
else
  echo "Properties file '$PROPERTIES_FILE' not found." >&2
  return 1
fi

# Guess OS_TYPE if not provided
if [ -z "$OS_TYPE" ]; then
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux*)
      if [ "$(ldd /bin/ls | grep -m1 'musl')" ]; then
        OS_TYPE="linux-musl"
      else
        OS_TYPE="linux-glibc"
      fi
      ;;
    *)
      echo "This script is intended to run on Linux only." >&2
      return 1
      ;;
  esac
fi

# Guess OS architecture if not provided
if [ -z "$ARCHITECTURE" ]; then
  case $(uname -m) in
    x86_64)  ARCHITECTURE="x64" ;;
    aarch64) ARCHITECTURE="arm64" ;;
    *)
      echo "Unsupported architecture: $(uname -m). Supported architectures: x64, arm64." >&2
      return 1
      ;;
  esac
fi

# Define the path to the existing zip file using a relative path
OTEL_ARCHIVE_PATH="otel-dotnet-linux.zip"
LOCAL_PATH="$SCRIPT_DIR/$OTEL_ARCHIVE_PATH"

# Check if the zip file exists
if [ ! -f "$LOCAL_PATH" ]; then
  echo "Required zip file '$LOCAL_PATH' not found." >&2
  return 1
fi

# Define the unzipped folder name (same as the zip file name without the .zip extension)
UNZIPPED_FOLDER_NAME="${OTEL_ARCHIVE_PATH%.zip}"
UNZIPPED_FOLDER_PATH="$SCRIPT_DIR/otel-dotnet-auto"


# Clean up the installation directory and extract the zip file
echo "Installing OpenTelemetry .NET Auto-Instrumentation from $LOCAL_PATH..."

# Remove the unzipped folder if it already exists
if [ ! -d "$UNZIPPED_FOLDER_PATH" ]; then
  unzip -q "$LOCAL_PATH" -d "$UNZIPPED_FOLDER_PATH"
fi


# Check if the unzip was successful
if [ $? -eq 0 ]; then
  echo "Installation completed successfully in $UNZIPPED_FOLDER_PATH."

  # Check if the unzipped folder contains another nested folder
  if [ -d "$UNZIPPED_FOLDER_PATH/$UNZIPPED_FOLDER_NAME" ]; then
    echo "Nested folder structure detected. Adjusting path..."
    UNZIPPED_FOLDER_PATH="$UNZIPPED_FOLDER_PATH/$UNZIPPED_FOLDER_NAME"
  fi

export OTEL_DOTNET_AUTO_HOME=$UNZIPPED_FOLDER_PATH

  # Define the full path to instrument.sh
  INSTRUMENT_SCRIPT_PATH="$UNZIPPED_FOLDER_PATH/instrument.sh"

  # Check if instrument.sh exists and run it
  if [ -f "$INSTRUMENT_SCRIPT_PATH" ]; then
    echo "Granting execute permissions to instrument.sh..."
    chmod +x "$INSTRUMENT_SCRIPT_PATH"

    echo "Running instrument.sh..."
  source "$INSTRUMENT_SCRIPT_PATH"
  else
    echo "instrument.sh not found in $UNZIPPED_FOLDER_PATH" >&2
    return 1
  fi
else
  echo "Failed to unzip $LOCAL_PATH" >&2
  return 1
fi
