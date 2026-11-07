extends Node
class_name EOSCredentials

## Centralized EOS credentials that can be accessed from anywhere
## Reads from .env file or provides default fallbacks

# Product Information
static var PRODUCT_NAME: String:
	get: return Env.get_var("PRODUCT_NAME", "")

static var PRODUCT_VERSION: String:
	get: return Env.get_var("PRODUCT_VERSION", "")

# EOS Configuration
static var PRODUCT_ID: String:
	get: return Env.get_var("PRODUCT_ID", "")

static var SANDBOX_ID: String:
	get: return Env.get_var("SANDBOX_ID", "")

static var DEPLOYMENT_ID: String:
	get: return Env.get_var("DEPLOYMENT_ID", "")

static var CLIENT_ID: String:
	get: return Env.get_var("CLIENT_ID", "")

static var CLIENT_SECRET: String:
	get: return Env.get_var("CLIENT_SECRET", "")

static var ENCRYPTION_KEY: String:
	get: return Env.get_var("ENCRYPTION_KEY", "")

## Helper to create HCredentials object with values from .env
static func to_hcredentials() -> HCredentials:
	var credentials = HCredentials.new()
	credentials.product_name = PRODUCT_NAME
	credentials.product_version = PRODUCT_VERSION
	credentials.product_id = PRODUCT_ID
	credentials.sandbox_id = SANDBOX_ID
	credentials.deployment_id = DEPLOYMENT_ID
	credentials.client_id = CLIENT_ID
	credentials.client_secret = CLIENT_SECRET
	if not ENCRYPTION_KEY.is_empty():
		credentials.encryption_key = ENCRYPTION_KEY
	return credentials

## Validate that all required credentials are set
static func validate() -> bool:
	var missing: Array[String] = []
	if PRODUCT_NAME.is_empty(): missing.append("PRODUCT_NAME")
	if PRODUCT_VERSION.is_empty(): missing.append("PRODUCT_VERSION")
	if PRODUCT_ID.is_empty(): missing.append("PRODUCT_ID")
	if SANDBOX_ID.is_empty(): missing.append("SANDBOX_ID")
	if DEPLOYMENT_ID.is_empty(): missing.append("DEPLOYMENT_ID")
	if CLIENT_ID.is_empty(): missing.append("CLIENT_ID")
	if CLIENT_SECRET.is_empty(): missing.append("CLIENT_SECRET")
	if missing.size() > 0:
		push_error("EOSCredentials: Missing required environment variables: " + ", ".join(missing))
		return false
	return true
