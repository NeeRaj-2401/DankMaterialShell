package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

type Event struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Location    string `json:"location"`
	Start       string `json:"start"`
	End         string `json:"end"`
	AllDay      bool   `json:"allDay"`
	Calendar    string `json:"calendar"`
	Color       string `json:"color"`
}

func parseDate(dateStr string) (time.Time, error) {
	// Handle different date formats used in iCalendar
	formats := []string{
		"20060102",           // YYYYMMDD
		"20060102T150405Z",   // YYYYMMDDTHHMMSSZ
		"20060102T150405",    // YYYYMMDDTHHMMSS
	}
	
	for _, format := range formats {
		if t, err := time.Parse(format, dateStr); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("unparseable date: %s", dateStr)
}

func isInDateRange(eventStart, eventEnd, rangeStart, rangeEnd string) bool {
	// Parse range dates
	startDate, err1 := time.Parse("2006-01-02", rangeStart)
	endDate, err2 := time.Parse("2006-01-02", rangeEnd)
	if err1 != nil || err2 != nil {
		return true // If we can't parse range, include the event
	}
	
	// Parse event start date
	evtStart, err3 := parseDate(eventStart)
	if err3 != nil {
		return true // If we can't parse event date, include it
	}
	
	// For all-day events (YYYYMMDD format), just check the date
	if len(eventStart) == 8 {
		return !evtStart.Before(startDate) && !evtStart.After(endDate.AddDate(0, 0, 1))
	}
	
	// For timed events, check overlap
	evtEnd := evtStart
	if eventEnd != "" {
		if parsed, err := parseDate(eventEnd); err == nil {
			evtEnd = parsed
		}
	}
	
	return !evtStart.After(endDate) && !evtEnd.Before(startDate)
}

func main() {
	// Read input from stdin
	scanner := bufio.NewScanner(os.Stdin)
	input := ""
	for scanner.Scan() {
		input += scanner.Text() + "\n"
	}
	
	// Get date range from environment variables or command line args
	startDateStr := os.Getenv("START_DATE")
	endDateStr := os.Getenv("END_DATE")
	
	if startDateStr == "" && len(os.Args) > 1 {
		startDateStr = os.Args[1]
	}
	if endDateStr == "" && len(os.Args) > 2 {
		endDateStr = os.Args[2]
	}
	
	var events []Event
	
	// Extract iCalendar strings from D-Bus output
	// Handle both quoted and unquoted formats
	re := regexp.MustCompile(`'([^']*BEGIN:VEVENT[^']*END:VEVENT[^']*)'`)
	matches := re.FindAllStringSubmatch(input, -1)
	
	// If no quoted matches, try unquoted
	if len(matches) == 0 {
		re2 := regexp.MustCompile(`BEGIN:VEVENT[^E]*END:VEVENT`)
		unquotedMatches := re2.FindAllString(input, -1)
		for _, match := range unquotedMatches {
			matches = append(matches, []string{match, match})
		}
	}
	
	for _, match := range matches {
		if len(match) < 2 {
			continue
		}
		
		icalData := match[1]
		// Unescape the iCalendar data
		icalData = strings.ReplaceAll(icalData, "\\r\\n", "\n")
		icalData = strings.ReplaceAll(icalData, "\\n", "\n")
		
		if !strings.Contains(icalData, "BEGIN:VEVENT") {
			continue
		}
		
		event := Event{
			Description: "",
			Location:    "",
			Calendar:    "Personal",
			Color:       "#1976d2",
		}
		
		lines := strings.Split(icalData, "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if !strings.Contains(line, ":") {
				continue
			}
			
			parts := strings.SplitN(line, ":", 2)
			if len(parts) != 2 {
				continue
			}
			
			key := strings.ToUpper(parts[0])
			value := parts[1]
			
			switch {
			case key == "UID":
				event.ID = value
			case key == "SUMMARY":
				event.Title = value
			case key == "DESCRIPTION":
				event.Description = value
			case key == "LOCATION":
				event.Location = value
			case strings.HasPrefix(key, "DTSTART"):
				event.Start = value
				event.AllDay = strings.Contains(line, ";VALUE=DATE:")
			case strings.HasPrefix(key, "DTEND"):
				event.End = value
			}
		}
		
		// Only include events with a title and within date range
		if event.Title != "" && isInDateRange(event.Start, event.End, startDateStr, endDateStr) {
			events = append(events, event)
		}
	}
	
	// Output JSON
	jsonData, err := json.Marshal(events)
	if err != nil {
		fmt.Fprintf(os.Stderr, "JSON marshal error: %v\n", err)
		fmt.Println("[]")
		return
	}
	
	fmt.Println(string(jsonData))
}
