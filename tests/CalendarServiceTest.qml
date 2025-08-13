import QtQuick
import QtTest
import qs.Services

TestCase {
    name: "CalendarServiceTest"
    
    property var calendarService: CalendarService
    
    function initTestCase() {
        console.log("Starting CalendarService tests")
        verify(calendarService !== null, "CalendarService should be available")
    }
    
    function test_serviceProperties() {
        verify(calendarService.hasOwnProperty("edsAvailable"), "Should have edsAvailable property")
        verify(calendarService.hasOwnProperty("goaAvailable"), "Should have goaAvailable property")
        verify(calendarService.hasOwnProperty("eventsByDate"), "Should have eventsByDate property")
        verify(calendarService.hasOwnProperty("isLoading"), "Should have isLoading property")
        verify(calendarService.hasOwnProperty("lastError"), "Should have lastError property")
        verify(calendarService.hasOwnProperty("servicesRunning"), "Should have servicesRunning property")
    }
    
    function test_serviceFunctions() {
        verify(typeof calendarService.checkEDSAvailability === "function", "Should have checkEDSAvailability function")
        verify(typeof calendarService.checkGOAAvailability === "function", "Should have checkGOAAvailability function")
        verify(typeof calendarService.loadCurrentMonth === "function", "Should have loadCurrentMonth function")
        verify(typeof calendarService.loadEvents === "function", "Should have loadEvents function")
        verify(typeof calendarService.getEventsForDate === "function", "Should have getEventsForDate function")
        verify(typeof calendarService.hasEventsForDate === "function", "Should have hasEventsForDate function")
        verify(typeof calendarService.refreshCalendars === "function", "Should have refreshCalendars function")
        verify(typeof calendarService.createEvent === "function", "Should have createEvent function")
        verify(typeof calendarService.listCalendarAccounts === "function", "Should have listCalendarAccounts function")
    }
    
    function test_getEventsForDate() {
        let testDate = new Date("2025-01-15")
        let events = calendarService.getEventsForDate(testDate)
        verify(Array.isArray(events), "getEventsForDate should return an array")
    }
    
    function test_hasEventsForDate() {
        let testDate = new Date("2025-01-15")
        let hasEvents = calendarService.hasEventsForDate(testDate)
        verify(typeof hasEvents === "boolean", "hasEventsForDate should return boolean")
    }
    
    function test_createEventBasic() {
        let title = "Test Event"
        let startDate = new Date("2025-01-20T10:00:00")
        let endDate = new Date("2025-01-20T11:00:00")
        let description = "Test event description"
        let location = "Test location"
        
        let result = calendarService.createEvent(title, startDate, endDate, description, location)
        verify(typeof result === "boolean", "createEvent should return boolean")
    }
    
    function test_eventsByDateStructure() {
        let eventsByDate = calendarService.eventsByDate
        verify(typeof eventsByDate === "object", "eventsByDate should be an object")
    }
    
    function test_dateRangeLoading() {
        let startDate = new Date("2025-01-01")
        let endDate = new Date("2025-01-31")
        
        // This should not crash
        calendarService.loadEvents(startDate, endDate)
        
        // Verify date range was stored
        if (calendarService.lastStartDate && calendarService.lastEndDate) {
            verify(calendarService.lastStartDate <= calendarService.lastEndDate, 
                   "Start date should be before or equal to end date")
        }
    }
    
    function test_serviceInitialization() {
        // The service should initialize its processes
        verify(calendarService.edsServices.length > 0, "Should have EDS services defined")
        verify(calendarService.cacheValidityMinutes > 0, "Should have cache validity defined")
        verify(calendarService.cacheFile.length > 0, "Should have cache file path defined")
    }
    
    function test_errorHandling() {
        // Test that lastError is a string
        verify(typeof calendarService.lastError === "string", "lastError should be a string")
    }
    
    function test_serviceAvailabilityCheck() {
        // These functions should be callable without crashing
        calendarService.checkEDSAvailability()
        calendarService.checkGOAAvailability()
        
        // Should not crash the service
        verify(calendarService !== null, "Service should still be available after availability checks")
    }
    
    function test_refreshFunctionality() {
        // Should be callable without crashing
        calendarService.refreshCalendars()
        
        verify(calendarService !== null, "Service should still be available after refresh")
    }
}