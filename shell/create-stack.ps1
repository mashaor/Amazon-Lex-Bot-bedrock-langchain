
# This name will be used across multiple resources. Must be lower case for S3 bucket naming convention
$STACK_NAME='companyname-lex'

# Public or internal HTTPS website for Kendra to index via Web Crawler (e.g., https://www.investopedia.com/) - Please see https://docs.aws.amazon.com/kendra/latest/dg/data-source-web-crawler.html
$KENDRA_WEBCRAWLER_URL= @(
    "https://Company.com/pages/faq",
    "https://support.Company.com"
)

$AWS_REGION='us-east-1' # Stack deployment region
$AWS_PROFILE = '309847704252_AWSAdministratorAccess' 

# Generate unique identifier
$UNIQUE_IDENTIFIER = [guid]::NewGuid().ToString().ToLower().Replace("-", "").Substring(0,5)

# Create S3 artifact bucket name
$S3_ARTIFACT_BUCKET_NAME = "$STACK_NAME-$UNIQUE_IDENTIFIER"

# Define S3 keys
$LAMBDA_HANDLER_S3_KEY = "agent/lambda/agent-handler/agent_deployment_package.zip"
$LEX_BOT_S3_KEY = "agent/bot/lex.zip"

Write-Host "STACK_NAME: $STACK_NAME"
Write-Host "S3_ARTIFACT_BUCKET_NAME: $S3_ARTIFACT_BUCKET_NAME"

# Create S3 bucket
Write-Host "Creating Bucket: ${S3_ARTIFACT_BUCKET_NAME}"
aws s3 mb "s3://$S3_ARTIFACT_BUCKET_NAME" --region $AWS_REGION --profile $AWS_PROFILE

#Upload the contents of the  "../agent/" directory to the "agent" directory within the S3 bucket.
$AGENT_PATH= (Resolve-Path -Path ".\agent\").Path
aws s3 cp $AGENT_PATH "s3://$S3_ARTIFACT_BUCKET_NAME/agent/" --region $AWS_REGION --recursive --exclude ".DS_Store" --exclude "*/.DS_Store" --profile $AWS_PROFILE

# Publish Lambda layers
Write-Host "Publish Lambda layers"
$BEDROCK_LANGCHAIN_PDFRW_LAYER_ARN = aws lambda publish-layer-version `
    --layer-name "bedrock-langchain-pdfrw" `
    --description "Bedrock LangChain pdfrw layer" `
    --license-info "MIT" `
    --content "S3Bucket=$S3_ARTIFACT_BUCKET_NAME,S3Key=agent/lambda/lambda-layers/bedrock-langchain-pdfrw.zip" `
    --compatible-runtimes python3.11 `
    --region $AWS_REGION `
    --query LayerVersionArn --output text `
    --profile $AWS_PROFILE

Write-Host $BEDROCK_LANGCHAIN_PDFRW_LAYER_ARN

$CFNRESPONSE_LAYER_ARN = aws lambda publish-layer-version `
    --layer-name "cfnresponse" `
    --description "cfnresponse Layer" `
    --license-info "MIT" `
    --content "S3Bucket=$S3_ARTIFACT_BUCKET_NAME,S3Key=agent/lambda/lambda-layers/cfnresponse-layer.zip" `
    --compatible-runtimes python3.11 `
    --region $AWS_REGION `
    --query LayerVersionArn --output text `
    --profile $AWS_PROFILE

Write-Host $CFNRESPONSE_LAYER_ARN 

# Create CloudFormation stack
$TEMPLATE_PATH= (Resolve-Path -Path ".\cfn\GenAI-FSI-Agent.yml").Path
Write-Host "Create CloudFormation stack"
aws cloudformation create-stack `
    --stack-name $STACK_NAME `
    --template-body file://$TEMPLATE_PATH `
    --parameters `
    "ParameterKey=S3ArtifactBucket,ParameterValue=$($S3_ARTIFACT_BUCKET_NAME)" `
    "ParameterKey=LambdaHandlerS3Key,ParameterValue=$($LAMBDA_HANDLER_S3_KEY)" `
    "ParameterKey=LexBotS3Key,ParameterValue=$($LEX_BOT_S3_KEY)" `
    "ParameterKey=BedrockLangChainPDFRWLayerArn,ParameterValue=$($BEDROCK_LANGCHAIN_PDFRW_LAYER_ARN)" `
    "ParameterKey=CfnresponseLayerArn,ParameterValue=$($CFNRESPONSE_LAYER_ARN)" `
    "ParameterKey=KendraWebCrawlerUrl,ParameterValue=$($KENDRA_WEBCRAWLER_URL)" `
    --capabilities CAPABILITY_NAMED_IAM `
    --region $AWS_REGION `
    --profile $AWS_PROFILE

# Check stack creation status
Write-Host "Check stack creation status"
aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION --query "Stacks[0].StackStatus" --profile $AWS_PROFILE
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $AWS_REGION --profile $AWS_PROFILE
aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION --query "Stacks[0].StackStatus" --profile $AWS_PROFILE

# Fetch Lex bot ID
Write-Host "Fetch Lex bot ID"
$LEX_BOT_ID = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $AWS_REGION `
    --query 'Stacks[0].Outputs[?OutputKey==`LexBotID`].OutputValue' --output text `
    --profile $AWS_PROFILE

Write-Host "LEX_BOT_ID: $LEX_BOT_ID"

# Fetch Lambda ARN
Write-Host "Fetch Lambda ARN"
$LAMBDA_ARN = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $AWS_REGION `
    --query 'Stacks[0].Outputs[?OutputKey==`LambdaARN`].OutputValue' --output text `
    --profile $AWS_PROFILE

Write-Host "LAMBDA_ARN: $LAMBDA_ARN"

# Update Lex bot alias
Write-Host "Update Lex bot alias"

$localeSettings = @"
{
  "en_US": {
    "enabled": true,
    "codeHookSpecification": {
      "lambdaCodeHook": {
        "lambdaARN": "$LAMBDA_ARN",
        "codeHookInterfaceVersion": "1.0"
      }
    }
  }
}
"@

aws lexv2-models update-bot-alias `
    --bot-alias-id 'TSTALIASID' `
    --bot-alias-name 'TestBotAlias' `
    --bot-id $LEX_BOT_ID `
    --bot-version 'DRAFT' `
    --bot-alias-locale-settings "$localeSettings" `
    --region $AWS_REGION `
    --profile $AWS_PROFILE

# Build Lex bot locale
Write-Host "Build Lex bot locale"
aws lexv2-models build-bot-locale --bot-id $LEX_BOT_ID --bot-version "DRAFT" --locale-id "en_US" --region $AWS_REGION --profile $AWS_PROFILE

# Fetch Kendra resources
Write-Host "Fetch Kendra resources"
$KENDRA_INDEX_ID = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $AWS_REGION `
    --query 'Stacks[0].Outputs[?OutputKey==`KendraIndexID`].OutputValue' --output text `
    --profile $AWS_PROFILE

Write-Host "KENDRA_INDEX_ID $KENDRA_INDEX_ID"

$KENDRA_DATA_SOURCE_ROLE_ARN = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $AWS_REGION `
    --query 'Stacks[0].Outputs[?OutputKey==`KendraDataSourceRoleARN`].OutputValue' --output text `
    --profile $AWS_PROFILE

Write-Host "KENDRA_DATA_SOURCE_ROLE_ARN $KENDRA_DATA_SOURCE_ROLE_ARN"

$KENDRA_WEBCRAWLER_DATA_SOURCE_ID = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $AWS_REGION `
    --query 'Stacks[0].Outputs[?OutputKey==`KendraWebCrawlerDataSourceID`].OutputValue' --output text `
    --profile $AWS_PROFILE

Write-Host "KENDRA_WEBCRAWLER_DATA_SOURCE_ID $KENDRA_WEBCRAWLER_DATA_SOURCE_ID"

# Start Kendra data source sync job
Write-Host "Start Kendra data source sync job"
aws kendra start-data-source-sync-job --id $KENDRA_WEBCRAWLER_DATA_SOURCE_ID --index-id $KENDRA_INDEX_ID --region $AWS_REGION --profile $AWS_PROFILE

#Create the first Lex Bot version (from DRAFT) and a new PROD alias

$localeSpecification = @"
{ 
    "en_US" : { 
       "sourceBotVersion": "DRAFT"
    }
 }
"@

#Create a new version of the bot
$CREATE_VERSION_RESPONSE = aws lexv2-models create-bot-version `
    --bot-id $LEX_BOT_ID `
    --bot-version-locale-specification "$localeSpecification" `
    --region $AWS_REGION `
    --profile $AWS_PROFILE

$NEW_BOT_VERSION = ($CREATE_VERSION_RESPONSE | ConvertFrom-Json).botVersion 

Write-Output "Created new version $NEW_BOT_VERSION"

$NEW_ALIAS = 'PROD'

#Create the PROD alias to point to the new version
aws lexv2-models create-bot-alias `
    --bot-id $LEX_BOT_ID `
    --bot-alias-name $NEW_ALIAS `
    --bot-version $NEW_BOT_VERSION `
    --bot-alias-locale-settings "$localeSettings" `
    --region $AWS_REGION `
    --profile $AWS_PROFILE

Write-Output "Created alias $NEW_ALIAS pointing to version $NEW_BOT_VERSION"

##### Create Lex Bot UI stack #####

#Get the new Alias ID
$LEX_BOT_ALIAS_ID = aws lexv2-models list-bot-aliases `
    --bot-id $LEX_BOT_ID `
    --region $AWS_REGION `
    --query "botAliasSummaries[?botAliasName=='$NEW_ALIAS'].botAliasId" --output text `
    --profile $AWS_PROFILE

Write-Host "LEX_BOT_ALIAS_ID $LEX_BOT_ALIAS_ID"

#Create CloudFormation stack for Lex UI

$UI_STACK_NAME = "$STACK_NAME-UI"
$UI_TEMPLATE_PATH= (Resolve-Path -Path ".\cfn\Lex-UI.yaml").Path

#this is the domain that the iFrame snippet will be accessed from. 
$SOURCE_URL= 'https://company.com'

Write-Host "Create CloudFormation stack for Lex UI"
aws cloudformation create-stack `
    --stack-name $UI_STACK_NAME `
    --template-body file://$UI_TEMPLATE_PATH `
    --parameters `
    "ParameterKey=LexV2BotId,ParameterValue=$($LEX_BOT_ID)" `
    "ParameterKey=LexV2BotAliasId,ParameterValue=$($LEX_BOT_ALIAS_ID)" `
    "ParameterKey=LexV2BotLocaleId,ParameterValue='en_US'" `
    "ParameterKey=WebAppParentOrigin,ParameterValue=$($SOURCE_URL)" `
    "ParameterKey=ShouldLoadIframeMinimized,ParameterValue=true" `
    "ParameterKey=CodeBuildName,ParameterValue=$($UI_STACK_NAME)" `
    "ParameterKey=WebAppConfToolbarTitle,ParameterValue='FAQ'" `
    "ParameterKey=WebAppConfBotInitialText,ParameterValue='How can I help?'" `
    "ParameterKey=ToolbarColor,ParameterValue='#757575'" `
    "ParameterKey=ChatBackgroundColor,ParameterValue='#FFFFFF'" `
    "ParameterKey=BotChatBubble,ParameterValue='#ECEFF1'" `
    "ParameterKey=CustomerChatBubble,ParameterValue='#80CBC4'" `
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND `
    --region $AWS_REGION `
    --profile $AWS_PROFILE

Write-Host "Check UI stack creation status"
aws cloudformation describe-stacks --stack-name $UI_STACK_NAME --region $AWS_REGION --query "Stacks[0].StackStatus" --profile $AWS_PROFILE
aws cloudformation wait stack-create-complete --stack-name $UI_STACK_NAME --region $AWS_REGION --profile $AWS_PROFILE
aws cloudformation describe-stacks --stack-name $UI_STACK_NAME --region $AWS_REGION --query "Stacks[0].StackStatus" --profile $AWS_PROFILE
