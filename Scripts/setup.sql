CREATE DATABASE IoTEdgeDB
GO

CREATE TABLE IoTEdgeDB.dbo.AggregatedMachineTemperature (timestamp DATETIME2, count INT, avg FLOAT, min FLOAT, max FLOAT, stdev FLOAT, var FLOAT, lag FLOAT, last FLOAT, anomalyscore FLOAT)
GO

CREATE TABLE IoTEdgeDB.dbo.RawMachineTemperature (timestamp DATETIME2, temperature FLOAT)
GO

CREATE LOGIN iotedgeaccount WITH PASSWORD = 'Strong!Passw0rd'
GO

USE IoTEdgeDB;
GO

IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = N'iotedgeaccount')
BEGIN
    CREATE USER [iotedgeaccount] FOR LOGIN [iotedgeaccount]
    EXEC sp_addrolemember N'db_owner', N'iotedgeaccount'
END;
GO