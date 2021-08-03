-- Create database
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name='IoTEdgeDB')
BEGIN
    CREATE DATABASE IoTEdgeDB;
END;
GO

USE IoTEdgeDB;
GO

-- Create tables
IF NOT EXISTS (SELECT * FROM sys.objects WHERE NAME = N'OpcNodes')
BEGIN
    CREATE TABLE OpcNodes (id [int] IDENTITY(1,1) NOT NULL, SourceTimestamp DATETIME2, NodeId VARCHAR(128), ApplicationUri VARCHAR(128), DipData FLOAT NULL, SpikeData FLOAT NULL, RandomSignedInt32 FLOAT NULL);
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE NAME = N'Models')
BEGIN

    CREATE TABLE Models (id [int] IDENTITY(1,1) NOT NULL, data [varbinary](max) NULL, description VARCHAR(128), applicationUri VARCHAR(128) NULL);
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE NAME = N'Predictions')
BEGIN

    CREATE TABLE Predictions (id [int] IDENTITY(1,1) NOT NULL, Timestamp DATETIME2, ApplicationUri VARCHAR(128) NULL, Prediction FLOAT NULL, Description VARCHAR(128) NULL);
END;
GO

-- Create login
CREATE LOGIN iotuser WITH PASSWORD = 'Strong!Passw0rd'
GO

-- Create database user
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = N'iotuser')
BEGIN
    CREATE USER [iotuser] FOR LOGIN [iotuser]
    EXEC sp_addrolemember N'db_owner', N'iotuser'
END;
GO
