$root_path = Split-Path $PSScriptRoot -Parent
Import-Module "$root_path/Scripts/PS-Library"


function New-Environment() {

    #region obtain ito hub name
    $iot_hubs = az iot hub list | ConvertFrom-Json | Sort-Object -Property id

    Write-Host
    Write-Host "Choose an IoT hub to use from this list (using its Index):"
    for ($index = 0; $index -lt $iot_hubs.Count; $index++) {
        Write-Host
        Write-Host "$($index + 1): $($iot_hubs[$index].id)"
    }
    while ($true) {
        $option = Read-Host -Prompt ">"
        try {
            if ([int]$option -ge 1 -and [int]$option -le $iot_hubs.Count) {
                break
            }
        }
        catch {
            Write-Host "Invalid index '$($option)' provided."
        }
        Write-Host "Choose from the list using an index between 1 and $($iot_hubs.Count)."
    }

    $iot_hub = $iot_hubs[$option - 1].name

    $twin_tag = "testStreamAnalytics=true"
    $target_condition = "tags.$($twin_tag)"
    Write-Host
    Write-Host -Foreground Yellow "NOTE: You must update your IoT edge device(s) twin by adding the tag `"$twin_tag`""
    #endregion

    $priority = (az iot edge deployment list -n $iot_hub `
        | ConvertFrom-Json `
        | Sort-Object -Property 'priority' -Descending)[0].priority

    #region SQL server
    Write-Host
    $option = Read-Host -Prompt "Create SQL edge deployment? [Y/N] (Default N)"

    if ($option -eq 'y') {
        Write-Host
        Write-Host "Creating SQL server deployment"

        $deployment_manifest = "$root_path/EdgeDeployments/sqlserver.manifest.json"
        $priority += 1
        az iot edge deployment create `
            --layered `
            -d "sql-$priority" `
            --pri $priority `
            -n $iot_hub `
            --tc "$target_condition" `
            --content $deployment_manifest
    }
    #endregion

    #region create OPC deployment
    $opc_publisher_deployment_manifest = "$root_path/EdgeDeployments/opc.manifest.json"
    
    Write-Host
    $option = Read-Host -Prompt "Deploy OPC Publisher? [Y/N] (Default N)"

    if ($option -eq 'y') {
        Write-Host
        Write-Host "Creating OPC publisher edge deployment"

        $priority += 1
        az iot edge deployment create `
            --layered `
            -d "opcpub-$priority" `
            --pri $priority `
            -n $iot_hub `
            --tc "$target_condition" `
            --content $opc_publisher_deployment_manifest
    }
    #endregion

    #region Edge ASA resource and edge deployments
    Write-Host
    $option = Read-Host -Prompt "Create edge stream analytics deployment? [Y/N] (Default N)"

    if ($option -eq 'y') {

        #region obtain edge asa job name
        $asa_jobs = az stream-analytics job list | ConvertFrom-Json
        if ($asa_jobs.Count -gt 0)
        {
            $options = @("Create new stream analytics job", "Use existing stream analytics job")
            Write-Host
            Write-Host "Choose an option from the list for the stream analytics job (using its Index):"
            for ($index = 0; $index -lt $options.Count; $index++)
            {
                # Write-Host
                Write-Host "$($index + 1): $($options[$index])"
            }
            while ($true)
            {
                $option = Read-Host -Prompt ">"
                try
                {
                    if ([int]$option -ge 1 -and [int]$option -le $options.Count)
                    {
                        break
                    }
                }
                catch
                {
                    Write-Host "Invalid index '$($option)' provided."
                }
                Write-Host "Choose from the list using an index between 1 and $($options.Count)."
            }

            #region choose existing job
            if ($option -eq 2)
            {
                Write-Host
                Write-Host "Choose a stream analytics job to use from this list (using its Index):"
                for ($index = 0; $index -lt $asa_jobs.Count; $index++)
                {
                    Write-Host
                    Write-Host "$($index + 1): $($asa_jobs[$index].id)"
                }
                while ($true)
                {
                    $option = Read-Host -Prompt ">"
                    try
                    {
                        if ([int]$option -ge 1 -and [int]$option -le $asa_jobs.Count)
                        {
                            break
                        }
                    }
                    catch
                    {
                        Write-Host "Invalid index '$($option)' provided."
                    }
                    Write-Host "Choose from the list using an index between 1 and $($asa_jobs.Count)."
                }

                $edge_asa_job = $asa_jobs[$option - 1].name
                $resource_group = $asa_jobs[$option - 1].resourceGroup

            }
            #endregion

            #region new stream analytics job
            else
            {
                $edge_asa_job = $null
                $first = $true
                while ([string]::IsNullOrEmpty($edge_asa_job) -or ($edge_asa_job -notmatch "^[a-z0-9-_]{3,}$"))
                {
                    if ($first -eq $false)
                    {
                        Write-Host "Use alphanumeric characters as well as '-' or '_'."
                    }
                    else
                    {
                        Write-Host
                        Write-Host "Please provide a name for the stream analytics job."
                        $first = $false
                    }
                    $edge_asa_job = Read-Host -Prompt ">"
                }
            }
            #endregion
        }
        #endregion

        #region obtain resource group name
        if (!$resource_group)
        {
            $first = $true
            while ([string]::IsNullOrEmpty($resource_group) -or ($resource_group -notmatch "^[a-z0-9-_]*$"))
            {
                if ($first -eq $false)
                {
                    Write-Host "Use alphanumeric characters as well as '-' or '_'."
                }
                else
                {
                    Write-Host
                    Write-Host "Please provide a name for the resource group."
                    $first = $false
                }
                $resource_group = Read-Host -Prompt ">"
            }

            $resourceGroup = az group show --name $resource_group | ConvertFrom-Json
            if (!$resourceGroup)
            {
                Write-Host "Resource group '$resource_group' does not exist."
                
                $resourceGroup = az group create --name $resource_group --location $location | ConvertFrom-Json
                Write-Host "Created new resource group $($resource_group) in $($resourceGroup.location)."
            }
        }
        #endregion

        # publish storage account name
        $storage_account = "$($resource_group)$($edge_asa_job)".Replace('-', '').Replace('_', '').ToLower()
        $storage_account = $storage_account.SubString(0, [System.Math]::Min($storage_account.Length, 20))

        #region Edge job settings
        $query = Get-Content -Path "$root_path/StreamAnalytics/StreamAnalytics.asaql" -Raw

        ### Set max writer count for SQL output
        ### 0 = inherit partition (use this)
        ### 1 = single writer. Currently there is a bug with this option when running at the edge
        $max_writer_count = 0
        #endregion

        #region resource group deployment
        $template_file = "$root_path/StreamAnalytics/Deploy/StreamAnalytics.JobTemplate.json"
        $parameters_file = "$root_path/StreamAnalytics/Deploy/StreamAnalytics.JobTemplate.parameters.json"

        $deployment_parameters = @{
            "StreamAnalyticsJobName" = @{ "value" = $edge_asa_job }
            "Query" = @{ "value" = ($query | Out-String) }
            "Output_opcnodesdboutput_server" = @{ "value" = "tcp:mssql,1433" }
            "Output_opcnodesdboutput_database" = @{ "value" = "IoTEdgeDB" }
            "Output_opcnodesdboutput_table" = @{ "value" = "dbo.OpcNodes" }
            "Output_opcnodesdboutput_user" = @{ "value" = "iotuser" }
            "Output_opcnodesdboutput_password" = @{ "value" = "Strong!Passw0rd" }
            "Output_opcnodesdboutput_maxWriterCount" = @{ "value" = $max_writer_count }
            "Output_opcnodesdboutput_maxBatchCount" = @{ "value" = 10000 }
            "Output_opcnodesdboutput_authenticationMode" = @{ "value" = "ConnectionString" }
            "Output_predictionsdboutput_server" = @{ "value" = "tcp:mssql,1433" }
            "Output_predictionsdboutput_database" = @{ "value" = "IoTEdgeDB" }
            "Output_predictionsdboutput_table" = @{ "value" = "dbo.Predictions" }
            "Output_predictionsdboutput_user" = @{ "value" = "iotuser" }
            "Output_predictionsdboutput_password" = @{ "value" = "Strong!Passw0rd" }
            "Output_predictionsdboutput_maxWriterCount" = @{ "value" = $max_writer_count }
            "Output_predictionsdboutput_maxBatchCount" = @{ "value" = 10000 }
            "Output_predictionsdboutput_authenticationMode" = @{ "value" = "ConnectionString" }
            "StorageAccountName" = @{ "value" = $storage_account }
        }

        Set-Content -Path $parameters_file -Value (ConvertTo-Json $deployment_parameters -Depth 15)

        Write-Host
        Write-Host "Deploying edge stream analytics job"

        $deployment_id = Get-date -Format 'yyMMddHHmm'
        $deployment_output = az deployment group create `
            --resource-group $resource_group `
            --name "EdgeASAJob-$deployment_id" `
            --mode Incremental `
            --template-file $template_file `
            --parameters $parameters_file | ConvertFrom-Json
        
        if (!$deployment_output)
        {
            return
        }
        Write-Host
        Write-Host "Deployment completed"
        #endregion

        #region publish edge stream analytics job
        Start-Sleep -Seconds 30
        
        Write-Host
        Write-Host "Publishing the edge job"

        $edge_manifest = Publish-EdgeJob `
            -resource_group $resource_group `
            -job_name $edge_asa_job

        if (!$edge_manifest)
        {
            return
        }
        Write-Host
        Write-Host "Publish completed"

        #region update edge job connection string
        Write-Host
        Write-Host "Updating edge job package connection string"
        
        $edge_job_package = Set-ASAEdgeJobConnectionString -blob_url $edge_manifest.twin.content.'properties.desired'.ASAJobInfo

        Write-Host
        Write-Host "Uploading edge job package '$($edge_job_package.LocalPath)' to storage account '$($edge_job_package.Account)', container '$($edge_job_package.Container)', path '$($edge_job_package.Path)/$($edge_job_package.Name)'"
        
        $storage_keys = az storage account keys list --account-name $edge_job_package.Account | ConvertFrom-Json
        az storage blob upload `
            --account-name $edge_job_package.Account `
            --container-name $edge_job_package.Container `
            --account-key $storage_keys[0].value `
            --name "$($edge_job_package.Path)/$($edge_job_package.Name)" `
            --file $edge_job_package.LocalPath
        
        Write-Host "Upload completed"
        #endregion

        #endregion

        #region stream analytics deployment

        # update IoT edge deployment with stream analytics job details
        $deployment_template = "$root_path/EdgeDeployments/streamanalytics.template.json"
        $deployment_manifest = "$root_path/EdgeDeployments/streamanalytics.manifest.json"

        (Get-Content -Path $deployment_template -Raw) | ForEach-Object {
            $_ -replace '__ASA_ENV__', (ConvertTo-Json -InputObject $edge_manifest.env -Depth 10) `
                -replace '__ASA_IMAGE_NAME__', $edge_manifest.settings.image `
                -replace '__ASA_INPUT__', $edge_manifest.endpoints.inputs[0] `
                -replace '__ASA_UPSTREAM_OUTPUT__', $edge_manifest.endpoints.outputs[0] `
                -replace '__DESIRED_PROPERTIES__', (ConvertTo-Json -InputObject $edge_manifest.twin.content.'properties.desired' -Depth 10)
        } | Set-Content -Path $deployment_manifest

        Write-Host
        Write-Host "Creating stream analytics deployment"

        $priority += 1
        az iot edge deployment create --layered -d "streamAnalytics-$priority" --pri $priority -n $iot_hub --tc "$target_condition" --content $deployment_manifest
        #endregion
    }
    #endregion

    #region create Python scorer deployment
    Write-Host
    $option = Read-Host -Prompt "Deploy Python scorer? [Y/N] (Default N)"

    if ($option -eq 'y') {

        $sql_scorer_deployment_manifest = "$root_path/EdgeDeployments/python-scorer.manifest.json"
        $module_path = "$root_path/EdgeModules/PythonScorer"

        Write-Host
        $option = Read-Host -Prompt "Build Docker image? [Y/N] (Default N)"

        if ($option -eq 'y') {
            Write-Host
            Write-Host "Building Docker image"

            $image_tag = Get-date -Format 'yyMMddHHmm'
            $image = "marvingarcia/python-onnx-scorer:$image_tag"
            $dockerfile = "$module_path/Dockerfile.amd64"
            docker build -t $image -f $dockerfile $module_path
            docker push $image

            Write-Host
            Write-Host "Creating deployment manifest"

            $sql_scorer_deployment_template = "$root_path/EdgeDeployments/python-scorer.template.json"
            
            (Get-Content -Path $sql_scorer_deployment_template -Raw) | ForEach-Object {
                $_ `
                    -replace '__IMAGE__', $image
            } | Set-Content -Path $sql_scorer_deployment_manifest
        }

        Write-Host
        Write-Host "Creating Python scorer deployment"

        $priority += 1
        az iot edge deployment create `
            --layered `
            -n $iot_hub `
            -d "pyscorer-$priority" `
            --pri $priority `
            --tc "$target_condition" `
            --content $sql_scorer_deployment_manifest
    }
    #endregion
}

New-Environment