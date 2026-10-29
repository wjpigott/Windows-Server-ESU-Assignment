# Define your tenant ID, client ID, and client secret, server is the name of the server to update, esulicensename is from the Azure portal Arc ESU license name, 
# and Azure Region Location.
#
$tenantId = ""
$clientId = ""
$clientSecret = ""
$subscriptionid = ""
$resourcegroup = ""
$server = ""
$esulicensename = ""
$location = ""
#
# Define the resource you want to access
$resource = "https://management.azure.com/"
# Define the token endpoint
$tokenEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/token"
# Define the body of the request
$body = @{
    'resource' = $resource
    'client_id' = $clientId
    'grant_type' = 'client_credentials'
    'client_secret' = $clientSecret
}
# Invoke the REST method to get the token
$response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body
# Extract the token from the response
$token = $response.access_token
# Output the token if needed by uncommenting out the following line
# $token
# Define the Azure API URL
$url = "https://management.azure.com/subscriptions/$subscriptionid/resourceGroups/$resourcegroup/providers/Microsoft.HybridCompute/machines/$server/licenseProfiles/default?api-version=2023-06-20-preview"
# Create headers with the Authorization token
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}
$esuBody = @{
    "location" = $location
    "properties" = @{
        "esuProfile" = @{
            "assignedLicense" = "/subscriptions/$subscriptionid/resourceGroups/$resourcegroup/providers/Microsoft.HybridCompute/licenses/$esulicensename"
        }
    }
}
# Convert the request body to JSON format
$bodyJson = $esuBody | ConvertTo-Json
# Make the REST API call
$responseEsu = Invoke-RestMethod -Uri $url -Headers $headers -Method Put -Body $bodyJson
$esuProfile = $responseEsU.properties.esuProfile
$esuProfile