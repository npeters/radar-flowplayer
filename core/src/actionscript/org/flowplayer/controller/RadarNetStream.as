package org.flowplayer.controller
{
    import flash.net.NetConnection;
    import flash.net.NetStream;
    import flash.net.URLLoader;
    import flash.net.URLRequest;
    import flash.events.*;
    import flash.utils.Timer;
    import mx.utils.*;

    public class RadarNetStream extends NetStream
    {
        // Provided by the application
        private var majorVersion:int = 2;
        private var minorVersion:int = 0;
        private var zoneId:int;
        private var customerId:int;
        private var initHost:String;
        private var reportHost:String;
        private var settingsUrl:String;
        
        private const radarVersion:int = 13;
        
        // connection URL - providerId depends on it
        private var videoUri:String = null;
        
        private var httpStreaming:Boolean = false;
        
        // A pointer to the function that accepts a log message.
        // The client application may override this if it wishes.
        private var _log:Function;
        
        private var clientReady:Boolean = false;
        private var interrupted:Boolean = false;
        
        // Delay betweek play() call and bandwidth measurement - needed because
        // in the first few seconds, the bandwidth hasn't settled yet and
        // measurement is not very reliable. This default value can be overridden
        // in the Streaming Radar settings file.
        private var bandwidthDelay:int = 4000;
        private var bandwidthInterval:int = 2000;
        private var bandwidthCount:int = 5;
        
        // Delay between play() call and measurement of number of buffer events,
        // i.e. now set to measure 'number of buffer events in the first minute
        // of playback' this is default value, can be overridden in XML
        private var bufferCountDelay:int = 60000;
        
        private var transactionId:uint = (function(min:uint, max:uint):uint {
            return Math.floor(Math.random() * (max - min + 1)) + min;
        }(1, uint.MAX_VALUE));
        
        // A unique string returned in the init response that uniquely identifies
        // the Radar session.
        private var requestSignature:String = '';
        
        // Used to identify the provider in reports
        private var providerZoneId:int = -1;
        private var providerCustomerId:int = -1;
        private var providerId:int = -1;
        
        // Error and probe types for reporting
        private const ErrorTypeConnectFailed:int = 2;
        private const ErrorTypeStreamNotFound:int = 3;
        
        private var rtmpProbeTypes:Object = {
            'StartupDelay': 5,
            'BufferEventsPerMin': 6,
            'CurrentKBPS': 7,
            'PlaybackKBPS': 48
        };
        
        private var httpStreamingProbeTypes:Object = {
            'StartupDelay': 50,
            'BufferEventsPerMin': 51,
            'CurrentKBPS': 52,
            'PlaybackKBPS': 53
        };
        
        // An array of probes buffered because they cannot be sent yet - this happens
        // if probes start before the cedexis.xml file has finished loading - after
        // it is loaded and parsed the buffered probes are unbuffered and sent
        private var reportsQueue:Array = new Array();
        
        private var userStartTime:Number = 0;
        private var actualStartTime:Number = 0;
        private var playStarted:Boolean = false;
        private var bandwidthTimer:Timer = null;
        private var bufferCountReported:Boolean = false;
        private var bufferEmptyCtr:int = 0;
        
        public function RadarNetStream(nc:NetConnection, settingsUrl:String, logger:*):void {
            this.settingsUrl = settingsUrl;
            
            if (logger) {
                this._log = logger;
            }
            
            if (nc && nc.connected) {
                super(nc);
                // Store connection URL to pick the correct providerId when XML
                // is loaded and parsed.
                videoUri = nc.uri;
            }
            
            // Need to bypass our overridden version of addEventListener in order
            // to install our NET_STATUS handler
            super.addEventListener(NetStatusEvent.NET_STATUS, onNetStatus);
        }
        
        private function beginDownloadSettings():void {
            var loader:URLLoader = new URLLoader();
            loader.addEventListener(Event.COMPLETE, onSettingsLoaded);
            loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onLoadSettingsError);
            loader.load(new URLRequest(this.settingsUrl));
        }
        
        private function onSettingsLoaded(e:Event):void {
            _log('Inside RadarNetStream::onSettingsLoaded');
            var config:XML = new XML(e.target.data);
            var regex:RegExp;
            
            // Set member variables from XML
            zoneId = config.zoneId;
            customerId = config.customerId;
            initHost = config.initHost;
            reportHost = config.reportHost;
            bandwidthDelay = config.bandwidthDelay;
            bandwidthInterval = config.bandwidthInterval;
            bandwidthCount = config.bandwidthCount;
            bufferCountDelay = config.bufferCountDelay;
            
            _log('Zone Id: ' + zoneId + '; Customer Id: ' + customerId +
                '; Init Host: ' + initHost + '; Report Host: ' + reportHost +
                '; Bandwidth Delay: ' + bandwidthDelay + 'ms; Buffer Measurement Delay: ' +
                bufferCountDelay + 'ms');
            
            var foundProvider:Boolean = false;
            for each (var provider:XML in config.providers.provider) {
                //_log('Checking regex: ' + provider.uriRegex);
                regex = new RegExp(provider.uriRegex, 'i');
                if (regex.test(videoUri)) {
                    providerZoneId = provider.providerZoneId;
                    providerCustomerId = provider.providerCustomerId;
                    providerId = provider.providerId;
                    _log('URI (' + videoUri + ') matched regex for Provider ID ' +
                        providerId + ' (' + provider.uriRegex + ')');
                    foundProvider = true;
                    break;
                }
            }
            
            if (foundProvider)
            {
                beginInitRequest();
                
                if (!interrupted) {
                    // Start timers
                    var timestamp:Number = (new Date()).getTime();
                    
                    // Start bandwidth measurements
                    var delay:Number = bandwidthDelay - (timestamp - actualStartTime);
                    //_log(StringUtil.substitute("\nTimestamp = {0}\nStart Time = {1}\nBandwidth Delay = {2}\nTimer Delay = {3}",
                    //    timestamp, actualStartTime, bandwidthDelay, delay));
                    delay = (delay < 20) ? 20 : delay;
                    _log(StringUtil.substitute('Beginning bandwidth measurements in {0}ms', delay));
                    var tempTimer:Timer = new Timer(delay, 1);
                    tempTimer.addEventListener(TimerEvent.TIMER, beginBandwidthMeasurements);
                    tempTimer.start();
                    
                    // Start buffer events per minute measurement
                    delay = bufferCountDelay - (timestamp - actualStartTime);
                    //_log(StringUtil.substitute("\nTimestamp = {0}\nStart Time = {1}\nBuffer Count Delay = {2}\nTimer Delay = {3}",
                    //    timestamp, actualStartTime, bufferCountDelay, delay));
                    delay = (delay < 20) ? 20 : delay;
                    _log(StringUtil.substitute('Counting buffer events in {0}ms', delay));
                    tempTimer = new Timer(delay, 1);
                    tempTimer.addEventListener(TimerEvent.TIMER, onReportBufferCount);
                    tempTimer.start();
                }
            }
            else {
                _log(videoUri + " didn't match any of the expected providers.");
            }
        }
        
        private function beginInitRequest():void {
            var loader:URLLoader = new URLLoader(),
                url:String,
                m:Number = (new Date()).getTime(),
                t:String = String(Math.round(m / 1000)),
                seed:String = StringUtil.substitute('i1-as-{0}-{1}-{2}-{3}-{4}-i',
                    majorVersion, minorVersion, zoneId, customerId, transactionId);
                    
            url = StringUtil.substitute('http://{0}.{1}/i1/{2}/{3}/xml?seed={0}',
                seed, initHost, t, transactionId);
            
            _log('Init URL: ' + url);
            loader.addEventListener(Event.COMPLETE, onInitResponse);
            loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onInitError);
            loader.load(new URLRequest(url));
        }
        
        private function onInitResponse(e:Event):void {
            var config:XML = new XML(e.target.data);
            requestSignature = config.requestSignature;
            _log("Init response received:\n" + config);
            clientReady = true;
            sendQueuedReports();
        }
        
        private function onInitError(e:SecurityErrorEvent):void {
            _log("Init error detected:\n" + e);
        }
        
        private function beginBandwidthMeasurements(e:TimerEvent):void {
            //_log('Inside RadarNetStream::beginBandwidthMeasurements');
            bandwidthTimer = new Timer(bandwidthInterval, bandwidthCount);
            bandwidthTimer.addEventListener(TimerEvent.TIMER, reportBandwidth);
            bandwidthTimer.start();
        }
        
        private function reportBandwidth(e:TimerEvent):void {
            //_log("Inside RadarNetStream::reportBandwidth\n" + this.getNetStreamInfoString());
            if (interrupted) {
                return;
            }
            
            var currentKBPS:int = super.info.currentBytesPerSecond * 8 / 1000;
            var playbackKBPS:int = super.info.playbackBytesPerSecond * 8 / 1000;
            //_log(StringUtil.substitute("\nCurrent KBPS = {0}\nPlayback KBPS = {1}", currentKBPS, playbackKBPS));
            
            report(currentKBPS, httpStreaming ?
                httpStreamingProbeTypes['CurrentKBPS'] :
                rtmpProbeTypes['CurrentKBPS']);
            
            report(playbackKBPS, httpStreaming ?
                httpStreamingProbeTypes['PlaybackKBPS'] :
                rtmpProbeTypes['PlaybackKBPS']);
        }
        
        private function onReportBufferCount(e:TimerEvent):void {
            reportBufferCount();
        }
        
        private function reportBufferCount():void {
            //_log('Inside RadarNetStream::reportBufferCount');
            if (interrupted || bufferCountReported) {
                return;
            }
            // Prevent re-entry
            bufferCountReported = true;
            
            var interval:int = (new Date()).getTime() - actualStartTime;
            var eventsPerMin:int = bufferEmptyCtr * 60000 / interval;
            //_log(StringUtil.substitute("\nEvents = {0}\nInterval = {1}\nEvents per min = {2}",
            //    bufferEmptyCtr, interval, eventsPerMin));
            
            report(eventsPerMin, httpStreaming ?
                httpStreamingProbeTypes['BufferEventsPerMin'] :
                rtmpProbeTypes['BufferEventsPerMin']);
        }
        
        private function onPlayStart():void {
            //_log('Inside RadarNetStream::onPlayStart (Start Time: ' + userStartTime + ')');
            if (!playStarted) {
                // Prevent re-entry
                playStarted = true;
                
                actualStartTime = new Date().getTime();
                var startDelay:Number = actualStartTime - userStartTime;
                
                // If it's taken longer than 10 seconds, then assume something must be wrong.
                if (10000 >= startDelay) {
                    _log("Time until playback started: " + startDelay + 'ms');
                    report(startDelay, httpStreaming ?
                        httpStreamingProbeTypes['StartupDelay'] :
                        rtmpProbeTypes['StartupDelay']);
                }
                
                // Start the process to download settings
                beginDownloadSettings();
            }
        }
        
        private function onPlayStop():void {
            //_log('Inside RadarNetStream::onPlayStop');
            reportBufferCount();
            interrupted = true;
        }
        
        private function onPause():void {
            //_log('Inside RadarNetStream::onPause');
            interrupted = true;
            
        }
        
        private function onStreamNotFound():void {
            //_log('Inside RadarNetStream::onStreamNotFound');
            interrupted = true;
            
            report(0, httpStreaming ?
                httpStreamingProbeTypes['StartupDelay'] :
                rtmpProbeTypes['StartupDelay'],
                ErrorTypeStreamNotFound);
            
            // Still need to download settings and make the init request in
            // order to report the error
            beginDownloadSettings();
        }
        
        private function sendQueuedReports():void {
            _log('Sending queued reports');
            var probeData:Object;
            if (clientReady) {
                // Send reports that were ready before settings were loaded and
                // init response received.
                while (0 < reportsQueue.length) {
                    probeData = reportsQueue.shift();
                    report(probeData.measuredValue, probeData.probeType, probeData.errorType);
                }
            }
        }
        
        private function onBufferEmpty():void {
            bufferEmptyCtr++;
        }
        
        private var netStatusHandlers:Object = {
            'NetStream.Play.Start': onPlayStart,
            'NetStream.Buffer.Empty': onBufferEmpty,
            'NetStream.Play.Stop': onPlayStop,
            'NetStream.Pause.Notify': onPause,
            'NetStream.Play.StreamNotFound': onStreamNotFound
        };
        
        private function onNetStatus(e:NetStatusEvent):void {
            //_log('Inside RadarNetStream::onNetStatus: ' + ObjectUtil.toString(e.info));
            if (e.info.code in netStatusHandlers) {
                netStatusHandlers[e.info.code]();
            }
        }
        
        private function onLoadSettingsError(e:SecurityErrorEvent):void {
            _log("Load settings error detected:\n" + e);
        }
        
        private function report(measuredValue:int, probeType:Number, errorType:int=0):void {
            _log('Reporting (value: ' + measuredValue +
                '; probe type: ' + probeType + '; error type: ' + errorType + ')');
            
            if (clientReady) {
                var url:String = makeReportUrl(measuredValue, probeType, errorType);
                if (url) {
                    _log('Report URL: ' + url);
                    var loader:URLLoader = new URLLoader();
                    loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onLoadReportSecurityError);
                    loader.load(new URLRequest(url));
                }
            }
            else {
                // Haven't finished getting settings and making the init request.
                // Cache the data to send later.
                var p:Object = new Object();
                p.probeType = probeType;
                p.measuredValue = measuredValue;
                p.errorType = errorType;
                reportsQueue.push(p);
            }
        }
        
        private function onLoadReportSecurityError(e:SecurityErrorEvent):void {
            _log("Inside RadarNetStream::onLoadReportSecurityError...this is" +
                " not a critical error, but it's best if the report server" +
                " provides a crossdomain.xml file allowing acccess to Flash" +
                " applications from the client's domain.");
        }
        
        public override function play(...args):void {
            //_log('Inside RadarNetStream::play');
            // the case of HTTP streaming
            if (null === videoUri || 'null' === videoUri) {
                httpStreaming = true;
                videoUri = String(args[0]);
            }
            
            userStartTime = new Date().getTime();
            
            // super.play(args) is not implemented in the AS3 compiler yet
            switch(args.length) {
                case 0:
                    super.play();
                    break;
                case 1:
                    super.play(args[0]);
                    break;
                case 2:
                    super.play(args[0], args[1]);
                    break;
                case 3:
                    super.play(args[0], args[1], args[2]);
                    break;
                case 4:
                    super.play(args[0], args[1], args[2], args[3]);
                    break;
                case 5:
                    super.play(args[0], args[1], args[2], args[3], args[4]);
                    break;
                case 6:
                    super.play(args[0], args[1], args[2], args[3], args[4], args[5]);
                    break;
                case 7:
                    super.play(args[0], args[1], args[2], args[3], args[4], args[5], args[6]);
                    break;
            }
        }
        
        private function makeReportUrl(measuredValue:int, probeType:Number, status:int=0):String {
            if (-1 === providerZoneId || -1 === providerCustomerId) {
                _log('providerZoneId and providerCustomerId not set');
                return null;
            }
            var value:int = (status === 0) ? measuredValue : 0;
            return StringUtil.substitute(
                'http://{0}/f1/{1}/{2}/{3}/{4}/{5}/{6}/{7}/?sig={1}',
                reportHost, requestSignature, providerZoneId, providerCustomerId,
                providerId, probeType, status, value);
        }
        
        private function getNetStreamInfoString():String {
            var s:String = "currentBytesPerSecond = " + super.info.currentBytesPerSecond +
                "\nplaybackBytesPerSecond = " + super.info.playbackBytesPerSecond;
            return s;
        }
        
        public function reportFailedConnection(uri:String):void {
            _log('Reporting failed connection for ' + uri);
            videoUri = uri;
            interrupted = true;
            report(0, rtmpProbeTypes['StartupDelay'], ErrorTypeConnectFailed);
            beginDownloadSettings();
        }
    }
}
