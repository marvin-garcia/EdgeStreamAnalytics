# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for
# full license information.

# Useful links:
# https://www.onnxruntime.ai/python/auto_examples/plot_convert_pipeline_vectorizer.html#sphx-glr-auto-examples-plot-convert-pipeline-vectorizer-py

import os
import sys
import json
import time
import pyodbc
import asyncio
import logging
import numpy as np
import pandas as pd
import onnxruntime as rt
from datetime import datetime
from six.moves import input
from azure.iot.device import MethodResponse
from azure.iot.device.aio import IoTHubModuleClient

sql_server = os.environ["SQL_SERVER"]
sql_database = os.environ["SQL_DATABASE"]
sql_username = os.environ["SQL_USERNAME"]
sql_password = os.environ["SQL_PASSWORD"]
models_table = os.environ["SQL_MODELS_TABLE"]
features_table = os.environ["SQL_FEATURES_TABLE"]
models_id_column_name = os.environ["SQL_MODELS_ID_COLUMN_NAME"]
predict_trigger_name = os.environ["PREDICT_TRIGGER_PROPERTY_NAME"]
predict_trigger_value = os.environ["PREDICT_TRIGGER_PROPERTY_VALUE"]
log_level = int(os.environ['LOG_LEVEL'])
timer_seconds = int(os.environ["TIMER_SECONDS"])

logger = logging.getLogger(__name__)
logger.setLevel(log_level)
formatter = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
handler = logging.StreamHandler(sys.stdout)
handler.setLevel(log_level)
handler.setFormatter(formatter)
logger.addHandler(handler)

def get_connection_string(server, database, username, password):
    db_connection_string = f'Driver={{ODBC Driver 17 for SQL Server}};Server={server};UID={username};PWD={password};Database={database};'
    return db_connection_string

def predict(applicationUri):
    prediction = None
    try:
        # create connector
        db_connection_string = get_connection_string(sql_server, sql_database, sql_username, sql_password)
        
        conn = pyodbc.connect(db_connection_string, autocommit=True)
        cursor = conn.cursor()

        # get ONNX model
        query = f'SELECT data FROM {models_table} WHERE applicationUri= \'{applicationUri}\''
        logger.debug(f'Models query: {query}')
        cursor.execute(query)
        onnx_model = cursor.fetchall()[0][0]
        logger.debug("ONNX Model: ")
        logger.debug(onnx_model)

        # get feature data
        query = f'SELECT TOP 1 DipData, SpikeData, RandomSignedInt32 FROM {features_table} WHERE ApplicationUri=\'{applicationUri}\' ORDER BY SourceTimestamp DESC'
        logger.debug(f'Features query: {query}')
        sql_query = pd.read_sql_query(query, conn)
        x_train = pd.DataFrame(sql_query, columns=['DipData', 'SpikeData', 'RandomSignedInt32'])
        sess = rt.InferenceSession(onnx_model)
        y_pred = np.full(shape=(len(x_train)), fill_value=np.nan)

        for i in range(len(x_train)):
            inputs = {}
            for j in range(len(x_train.columns)):
                inputs[x_train.columns[j]] = np.full(shape=(1,1), fill_value=x_train.iloc[i,j])

            sess_pred = sess.run(None, inputs)
            y_pred[i] = sess_pred[0][0][0]

        prediction = y_pred.tolist()
        logger.debug("Prediction result: ")
        logger.debug(prediction)
        return prediction
    except Exception as e:
        logging.exception(e)
        return prediction

async def main():
    try:
        if not sys.version >= "3.5.3":
            raise Exception( "The sample requires python 3.5.3+. Current version of Python: %s" % sys.version )
        logger.info("IoT Hub Client for Python")

        # The client object is used to interact with your Azure IoT hub.
        module_client = IoTHubModuleClient.create_from_edge_environment()
        
        # connect the client.
        await module_client.connect()

        # define C2D behavior
        async def message_handler(message):
            try:
                data = json.loads(message.data)
                logger.debug(f'Received new input message: ')
                logger.debug(message.data)

                # Add any logic here to determine whether to make a prediction
                triggers = list(filter(lambda x: x['DisplayName'] == predict_trigger_value, data))
                logger.info(f'detected {len(triggers)} triggers in message (predict trigger: {predict_trigger_value})')
                if len(triggers) > 0:
                    for trigger in triggers:
                        logger.debug('calling predict method')
                        prediction = predict(trigger['ApplicationUri'])
                        if prediction:
                            output_message = {
                                'Timestamp': str(datetime.utcnow()),
                                'ApplicationUri': trigger['ApplicationUri'],
                                'Prediction': prediction[0],
                                'Description': 'Triggered from input event'
                            }

                            logger.debug("Sending output message: ")
                            logger.debug(json.dumps(output_message))
                            await module_client.send_message_to_output(json.dumps(output_message), "predictionoutput")
            except Exception as e:
                logger.exception(e)

        # define direct method behavior
        async def direct_method_handler(method_request):
            try:
                name = method_request.name
                data = method_request.payload
                logger.info(f'Direct method {name} invoked:')
                logger.debug(data)

                if name == "Predict":
                    prediction = predict(data['applicationUri'])
                    if prediction:
                        output_message = {
                            'Timestamp': str(datetime.utcnow()),
                            'ApplicationUri': data['applicationUri'],
                            'Prediction': prediction[0],
                            'Description': 'Triggered from direct method'
                        }

                        logger.debug("Sending output message: ")
                        logger.debug(json.dumps(output_message))
                        await module_client.send_message_to_output(json.dumps(output_message), "predictionoutput")
                        await module_client.send_method_response(MethodResponse(method_request.request_id, 200, output_message))
                    else:
                        error = { "message": "Unable to make prediction. See logs for more details" }
                        await module_client.send_method_response(MethodResponse(method_request.request_id, 500, error))
                else:
                    error = { "message": f'Method {name} is not declared' }
                    await module_client.send_method_response(MethodResponse(method_request.request_id, 500, error))
            except Exception as e:
                logger.exception(e)
                error = { "exception": str(e) }
                await module_client.send_method_response(MethodResponse(method_request.request_id, 500, error))

        # define behavior for halting the application
        def infinite_loop():
            counter = 0
            while True:
                try:
                    # Add any logic here to make predictions recurrently
                    counter += 1
                    if counter >= 10:
                        # reset counter
                        counter = 0
                    time.sleep(timer_seconds)
                except:
                    time.sleep(timer_seconds)

        # Schedule task for C2D Listener
        module_client.on_message_received = message_handler
        module_client.on_method_request_received = direct_method_handler

        logger.info("Module is now waiting for messages.")

        # Run the stdin listener in the event loop
        loop = asyncio.get_event_loop()
        thread_finished = loop.run_in_executor(None, infinite_loop)

        # Wait for user to indicate they are done listening for messages
        await thread_finished

        # Finally, disconnect
        await module_client.disconnect()

    except Exception as e:
        logger.exception(e)
        raise

if __name__ == "__main__":
    # loop = asyncio.get_event_loop()
    # loop.run_until_complete(main())
    # loop.close()

    # If using Python 3.7 or above, you can use following code instead:
    asyncio.run(main())