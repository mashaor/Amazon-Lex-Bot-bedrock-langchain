import os
import time
import boto3

from fsi_agent import FSIAgent
from langchain.llms.bedrock import Bedrock

# Instantiate boto3 clients and resources
boto3_session = boto3.Session(region_name=os.environ['AWS_REGION'])
bedrock_client = boto3_session.client(service_name="bedrock-runtime")

# --- Lex v2 request/response helpers (https://docs.aws.amazon.com/lexv2/latest/dg/lambda-response-format.html) ---

def elicit_intent(intent_request, session_attributes, message):
    """
    Constructs a response to elicit the user's intent during conversation.
    """
    response = {
        'sessionState': {
            'dialogAction': {
                'type': 'ElicitIntent'
            },
            'sessionAttributes': session_attributes
        },
        'messages': [
            {
                'contentType': 'PlainText', 
                'content': message
            },
            {
                'contentType': 'ImageResponseCard',
                'imageResponseCard': {
                    "buttons": [
                         {
                             "text": "Return Policy",
                             "value": "What is your return policy?"
                         },
                         {
                            "text": "Smart Devices",
                            "value": "Which smart devices Company integrates with?"
                        },
                        {
                            "text": "Contact Information",
                            "value": "How can I contact you?"
                        } 
                    ],
                    "title": "How can I help you?"
                }
            }     
        ]
    }

    return response

def delegate(session_attributes, active_contexts, intent, message):
    """
    Delegates the conversation back to the system for handling.
    """
    response = {
        'sessionState': {
            'activeContexts':[{
                'name': 'intentContext',
                'contextAttributes': active_contexts,
                'timeToLive': {
                    'timeToLiveInSeconds': 86400,
                    'turnsToLive': 20
                }
            }],
            'sessionAttributes': session_attributes,
            'dialogAction': {
                'type': 'Delegate',
            },
            'intent': intent,
        },
        'messages': [{'contentType': 'PlainText', 'content': message}]
    }

    return response


def invoke_agent(prompt):
    """
    Invokes Amazon Bedrock-powered LangChain agent with 'prompt' input.
    """
    #chat = Chat(prompt)
    llm = Bedrock(client=bedrock_client, model_id="anthropic.claude-v2:1", region_name=os.environ['AWS_REGION']) # anthropic.claude-instant-v1 / anthropic.claude-3-sonnet-20240229-v1:0
    llm.model_kwargs = {'max_tokens_to_sample': 350}
    lex_agent = FSIAgent(llm)
    
    # formatted_prompt = "\n\nHuman: " + prompt + " \n\nAssistant:"
    message = lex_agent.run(input=prompt)

    return message


def dispatch(intent_request):
    """
    Routes the incoming request based on intent.
    """
    session_attributes = intent_request['sessionState'].get("sessionAttributes") or {}
    
    if intent_request['invocationSource'] == 'DialogCodeHook':
        prompt = intent_request['inputTranscript']
        output = invoke_agent(prompt)
        print("FSI Agent response: " + str(output))

    return elicit_intent(intent_request, session_attributes, output)

        
# --- Main handler ---

def handler(event, context):
    """
    Invoked when the user provides an utterance that maps to a Lex bot intent.
    The JSON body of the user request is provided in the event slot.
    """
    os.environ['TZ'] = 'America/New_York'
    time.tzset()

    return dispatch(event)