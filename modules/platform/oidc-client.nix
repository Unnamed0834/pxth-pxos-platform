


{
  id,
  name,
  secret,
  redirectUris,
  scopes,
  authMethod,
  pkce ? false,
  grants ? [ "authorization_code" ],
}:
{
  client_id = id;
  client_name = name;
  client_secret = secret;
  public = false;
  authorization_policy = "one_factor";
  consent_mode = "implicit";
  redirect_uris = redirectUris;
  inherit scopes;
  response_types = [ "code" ];
  grant_types = grants;
  token_endpoint_auth_method = authMethod;
}
// (
  if pkce then
    {
      require_pkce = true;
      pkce_challenge_method = "S256";
    }
  else
    { }
)
