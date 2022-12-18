import { LightningElement, track} from 'lwc';
import buttonclick from '@salesforce/resourceUrl/buttonClicked';

export default class SimpleCalculator extends LightningElement {
    showResultHistory=false;
   @track arrayOfHistory=[""];
    firstNumber;
    secondNumber;
    @track result;
    buttonclicked=buttonclick;
    playAudio() {
        let audio = new Audio();
        audio.src = this.buttonclicked;
        audio.load();
        audio.play();

    }
    

    calculatorInput(evt)
    {
        console.log(evt.target.name);
        if(evt.target.name=="FirstNumber")
        {
           this.firstNumber=evt.target.value;
        }
        else if(evt.target.name=="SecondNumber")
        {
            this.secondNumber=evt.target.value;
        }

    }

    doAdd(evt)
    {
        this.playAudio();
        this.result=`${this.firstNumber} + ${this.secondNumber} = ${parseInt(this.firstNumber)+parseInt(this.secondNumber)}`;
        this.arrayOfHistory.unshift(this.result);
        
    }
    doSub(evt)
    {
        this.playAudio();
        this.result=`${this.firstNumber} - ${this.secondNumber} = ${parseInt(this.firstNumber)-parseInt(this.secondNumber)}`;
        this.arrayOfHistory.unshift(this.result);
    }
    doMul(evt)
    {
        this.playAudio();
        this.result=`${this.firstNumber} * ${this.secondNumber} = ${parseInt(this.firstNumber)*parseInt(this.secondNumber)}`;
        this.arrayOfHistory.unshift(this.result);
    }
    doDiv(evt)
    {
        this.playAudio();
        this.result=`${this.firstNumber} / ${this.secondNumber} = ${parseInt(this.firstNumber)/parseInt(this.secondNumber)}`;
        this.arrayOfHistory.unshift(this.result);
    }

    showCalculatorHistory(event)
    {
        this.showResultHistory= event.target.checked;
    }

    clearArray()
    {
        this.arrayOfHistory=[""]; 
    }
}